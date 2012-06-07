package AnyEvent::Task::Client::Checkout;

use common::sense;

use Scalar::Util;
use Guard;

use overload fallback => 1,
             '&{}' => \&invoked_as_sub;

our $AUTOLOAD;


sub new {
  my ($class, %arg) = @_;
  my $self = {};
  bless $self, $class;

  $self->{client} = $arg{client};
  Scalar::Util::weaken($self->{client});

  $self->{timeout} = exists $arg{timeout} ? $arg{timeout} :
                     exists $arg{client}->{timeout} ? $arg{client}->{timeout} :
                     30;

  $self->{on_error} = $arg{on_error} || sub {};

  $self->{pending_requests} = [];

  return $self;
}

sub AUTOLOAD {
  my $self = shift;

  my $type = ref($self) or die "$self is not an object";

  my $name = $AUTOLOAD;
  $name =~ s/.*://;

  return $self->queue_request([ $name, @_, ]) if wantarray;

  $self->queue_request([ $name, @_, ]);
  return;
}

sub invoked_as_sub {
  my $self = shift;

  return sub {
    return $self->queue_request([ @_, ]) if wantarray;

    $self->queue_request([ @_, ]);
    return;
  };
}

sub queue_request {
  my ($self, $request) = @_;

  die "can't perform request on checkout because an error occurred: $self->{error_occurred}"
    if exists $self->{error_occurred};

  push @{$self->{pending_requests}}, $request;

  $self->install_timeout_timer;

  $self->try_to_fill_requests;

  if (wantarray) {
    return guard {
      ## FIXME: abort request and/or whole checkout?
    };
  }
}

sub install_timeout_timer {
  my ($self) = @_;

  return if !defined $self->{timeout};
  return if exists $self->{timeout_timer};

  $self->{timeout_timer} = AE::timer $self->{timeout}, 0, sub {
    $self->{client}->remove_pending_checkout($self);

    if (exists $self->{worker}) {
      $self->{client}->destroy_worker($self->{worker});
      delete $self->{worker};
    }

    my $err = "timed out after $self->{timeout} seconds";

    {
      local $@ = $err;
      $self->{on_error}->();
    }

    $self->{error_occurred} = $err;
  };
}

sub try_to_fill_requests {
  my ($self) = @_;

  return unless exists $self->{worker};
  return unless @{$self->{pending_requests}};

  my $request = shift @{$self->{pending_requests}};

  my $cb = pop @{$request};

  $self->install_timeout_timer;

  $self->{worker}->push_write( json => [ 'do', {}, @$request, ], );

  $self->{worker}->push_read( json => sub {
    my ($handle, $response) = @_;

    my ($response_code, $meta, $response_value) = @$response;

    if ($response_code eq 'ok') {
      local $@ = undef;
      $cb->($self, $response_value);
    } elsif ($response_code eq 'er') {
      local $@ = $response_value;
      $cb->($self);
    } elsif ($response_code eq 'sk') {
      die "sk not implemented";
    } else {
      die "Unrecognized response_code: $response_code";
    }

    delete $self->{timeout_timer};

    $self->try_to_fill_requests;
  });
}

sub DESTROY {
  my ($self) = @_;

  $self->{client}->remove_pending_checkout($self);

  if (exists $self->{worker}) {
    $self->{client}->make_worker_available($self->{worker});
    delete $self->{worker};
    $self->{client}->try_to_fill_pending_checkouts;
  }
}


1;
