package AnyEvent::Task::Client;

use common::sense;
use AnyEvent;
use AnyEvent::Util;
use AnyEvent::Handle;
use AnyEvent::Socket;

use AnyEvent::Task::Client::Checkout;


sub new {
  my ($class, %arg) = @_;
  my $self = {};
  bless $self, $class;

  $self->{connect} = $arg{connect} || die "need connect";

  $self->{min_workers} = $arg{min_workers} || 2;
  $self->{max_workers} = $arg{max_workers} || 20;
  $self->{min_workers} = $self->{max_workers} if $self->{min_workers} > $self->{max_workers};

  $self->{total_workers} = 0;
  $self->{connecting_workers} = {};
  $self->{available_workers} = {};
  $self->{occupied_workers} = {};

  $self->{pending_checkouts} = [];

  $self->populate_workers;

  return $self;
}



sub populate_workers {
  my ($self) = @_;

  return if $self->{total_workers} >= $self->{max_workers};

  my $workers_to_create = $self->{min_workers} - $self->{total_workers};
  if ($workers_to_create <= 0) {
    $workers_to_create = 0;
    $workers_to_create = 1 unless keys %{$self->{available_workers}} || keys %{$self->{connecting_workers}};
  }

  for (1 .. $workers_to_create) {
    $self->{total_workers}++;

    my $host = $self->{connect}->[0];
    my $service = $self->{connect}->[1];

    my $worker_guard;
    $self->{connecting_workers}->{$worker_guard} = $worker_guard = tcp_connect $host, $service, sub {
      my $fh = shift;

      delete $self->{connecting_workers}->{$worker_guard};

      if (!$fh) {
        $self->{total_workers}--;
        $self->install_populate_workers_timer;
        return;
      }

      delete $self->{populate_workers_timer};

      my $worker; $worker = new AnyEvent::Handle
                              fh => $fh,
                              on_read => sub { }, ## So we always have a read watcher and can instantly detect worker deaths
                              on_error => sub {
                                my ($worker, $fatal, $message) = @_;
                                print STDERR "connection to worker died\n";
                                $self->destroy_worker($worker);
                                $self->populate_workers;
                              };

      $self->{available_workers}->{$worker} = $worker;

      $self->try_to_fill_pending_checkouts;
    };
  }

}


sub install_populate_workers_timer {
  my ($self) = @_;

  return if exists $self->{populate_workers_timer};

  $self->{populate_workers_timer} = AE::timer 0.2, 1, sub {
    $self->populate_workers;
  };
}


sub try_to_fill_pending_checkouts {
  my ($self) = @_;

  return unless @{$self->{pending_checkouts}};

  if (keys %{$self->{available_workers}}) {
    my @available_workers = values %{$self->{available_workers}};
    my $worker = shift @available_workers;
    $self->make_worker_occupied($worker);

    my $checkout = shift @{$self->{pending_checkouts}};
    $checkout->{worker} = $worker;

    $checkout->try_to_fill_requests;
    return $self->try_to_fill_pending_checkouts;
  }

  $self->populate_workers;
}



sub make_worker_occupied {
  my ($self, $worker) = @_;
  delete $self->{available_workers}->{$worker};
  $self->{occupied_workers}->{$worker} = $worker;
}


sub make_worker_available {
  my ($self, $worker) = @_;
  delete $self->{occupied_workers}->{$worker};
  $self->{available_workers}->{$worker} = $worker;
}

sub destroy_worker {
  my ($self, $worker) = @_;
  $self->{total_workers}--;
  delete $self->{available_workers}->{$worker};
  delete $self->{occupied_workers}->{$worker};
}


sub checkout {
  my ($self, @args) = @_;

  my $checkout = AnyEvent::Task::Client::Checkout->new( client => $self, @args, );

  push @{$self->{pending_checkouts}}, $checkout;

  $self->try_to_fill_pending_checkouts;

  return $checkout;
}

sub remove_pending_checkout {
  my ($self, $checkout) = @_;

  my @out;

  $self->{pending_checkouts} = [ grep { $_ != $checkout } @{$self->{pending_checkouts}} ];
}

1;
