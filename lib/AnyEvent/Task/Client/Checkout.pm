package AnyEvent::Task::Client::Checkout;

use common::sense;

use Scalar::Util;
use Guard;

use Callback::Frame;


use overload fallback => 1,
             '&{}' => \&invoked_as_sub;

our $AUTOLOAD;


sub _new {
  my ($class, %arg) = @_;
  my $self = {};
  bless $self, $class;

  $self->{client} = $arg{client};
  Scalar::Util::weaken($self->{client});

  $self->{timeout} = exists $arg{timeout} ? $arg{timeout} :
                     exists $arg{client}->{timeout} ? $arg{client}->{timeout} :
                     30;

  $self->{pending_requests} = [];

  return $self;
}

sub AUTOLOAD {
  my $self = shift;

  my $type = ref($self) or die "$self is not an object";

  my $name = $AUTOLOAD;
  $name =~ s/.*://;

  return $self->queue_request([ $name, @_, ]);
}

sub invoked_as_sub {
  my $self = shift;

  return sub {
    return $self->queue_request([ @_, ]);
  };
}

sub queue_request {
  my ($self, $request) = @_;

  die "can't perform request on checkout because an error occurred: $self->{error_occurred}"
    if exists $self->{error_occurred};

  $request->[-1] = frame(code => $request->[-1])
    unless Callback::Frame::is_frame($request->[-1]);

  push @{$self->{pending_requests}}, $request;

  $self->install_timeout_timer;

  $self->try_to_fill_requests;

  return;
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

    $self->throw_error("timed out after $self->{timeout} seconds");
  };
}

sub throw_error {
  my ($self, $err) = @_;

  my $current_cb;

  if ($self->{current_cb}) {
    $current_cb = $self->{current_cb};
  } elsif (@{$self->{pending_requests}}) {
    $current_cb = $self->{pending_requests}->[0]->[-1];
  }

  if ($current_cb) {
    frame(existing_frame => $current_cb,
          code => sub {
      die $err;
    })->();
  }

  $self->{error_occurred} = $err;
}

sub throw_error_non_fatal {
  my ($self, $err) = @_;

  $self->{error_is_non_fatal} = 1;
  $self->throw_error($err);
}

sub try_to_fill_requests {
  my ($self) = @_;

  return unless exists $self->{worker};
  return unless @{$self->{pending_requests}};

  my $request = shift @{$self->{pending_requests}};

  my $cb = pop @{$request};
  $self->{current_cb} = $cb;

  $self->install_timeout_timer;

  $self->{worker}->push_write( json => [ 'do', {}, @$request, ], );

  my $cmd_handler; $cmd_handler = sub {
    my ($handle, $response) = @_;

    my ($response_code, $meta, $response_value) = @$response;

    $self->{worker_wants_to_shutdown} = 1 if $meta->{sk};

    if ($response_code eq 'ok') {
      local $@ = undef;
      $cb->($self, $response_value);
    } elsif ($response_code eq 'er') {
      $self->throw_error_non_fatal($response_value);
    } elsif ($response_code eq 'sk') {
      $self->{worker_wants_to_shutdown} = 1;
      $self->{worker}->push_read( json => $cmd_handler );
      return;
    } else {
      die "Unrecognized response_code: $response_code";
    }

    delete $self->{current_cb};
    delete $self->{timeout_timer};
    undef $cmd_handler; # reference keeps checkout from being destroyed

    $self->try_to_fill_requests;
  };

  $self->{worker}->push_read( json => $cmd_handler );
}

sub DESTROY {
  my ($self) = @_;

  $self->{client}->remove_pending_checkout($self);

  if (exists $self->{worker}) {
    my $worker = $self->{worker};
    delete $self->{client}->{workers_to_checkouts}->{$worker};
    delete $self->{worker};

    if ($self->{error_occurred} && !$self->{error_is_non_fatal}) {
      $self->{client}->destroy_worker($worker);
      $self->populate_workers;
    } else {
      $worker->push_write( json => [ 'dn', {} ] );
      $self->{client}->make_worker_available($worker);
      $self->{client}->try_to_fill_pending_checkouts;
    }
  }
}


1;
