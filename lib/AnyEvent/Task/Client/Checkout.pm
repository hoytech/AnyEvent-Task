package AnyEvent::Task::Client::Checkout;

use common::sense;

use Scalar::Util;

use Callback::Frame;
use RPC::Pipelined::Client;


use overload fallback => 1,
             '&{}' => \&_invoked_as_sub;

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

  $self->{log_defer_object} = $arg{log_defer_object} if exists $arg{log_defer_object};

  $self->{rpc_client} = RPC::Pipelined::Client->new;

  $self->{pending_requests} = [];

  return $self;
}

sub AUTOLOAD {
  my $self = shift;

  my $type = ref($self) or die "$self is not an object";

  my $name = $AUTOLOAD;
  $name =~ s/.*://;

  $self->{last_name} = $name;

  return $self->_queue_request([ $name, @_, ]);
}

sub _invoked_as_sub {
  my $self = shift;

  return sub {
    $self->{last_name} = '->()';

    return $self->_queue_request([ @_, ]);
  };
}

sub _queue_request {
  my ($self, $request) = @_;

  if (ref $request->[-1] ne 'CODE') {
    return $self->{rpc_client}->run(@$request);
  }

  my $cb = pop @$request;

  unless (Callback::Frame::is_frame($cb)) {
    my $name = undef;

    if (defined $self->{client}->{name} || defined $self->{last_name}) {
      $name = defined $self->{client}->{name} ? $self->{client}->{name} : 'ANONYMOUS CLIENT';
      $name .= ' -> ';
      $name .= defined $self->{last_name} ? $self->{last_name} : 'NO METHOD';
    }

    my %args = (code => $cb);

    $args{name} = $name if defined $name;

    $cb = frame(%args)
      unless Callback::Frame::is_frame($cb);
  }

  $self->{rpc_client}->run(@$request);

  my $prepared_msg = $self->{rpc_client}->prepare;

  push @{$self->{pending_requests}}, [ $prepared_msg, $self->{last_name}, $cb, ];

  $self->_install_timeout_timer;

  $self->_try_to_fill_requests;

  return;
}

sub _install_timeout_timer {
  my ($self) = @_;

  return if !defined $self->{timeout};
  return if exists $self->{timeout_timer};

  $self->{timeout_timer} = AE::timer $self->{timeout}, 0, sub {
    $self->{client}->remove_pending_checkout($self);

    if (exists $self->{worker}) {
      $self->{client}->destroy_worker($self->{worker});
      delete $self->{worker};
    }

    $self->throw_fatal_error("timed out after $self->{timeout} seconds");
  };
}

sub _throw_error {
  my ($self, $err) = @_;

  $self->{error_occurred} = 1;

  my $current_cb;

  if ($self->{current_cb}) {
    $current_cb = $self->{current_cb};
  } elsif (@{$self->{pending_requests}}) {
    $current_cb = $self->{pending_requests}->[0]->[-1];
  } else {
    die "_throw_error called but no callback installed. Error thrown was: $err";
  }

  $self->{pending_requests} = undef;

  if ($current_cb) {
    frame(existing_frame => $current_cb,
          code => sub {
      die $err;
    })->();
  }
}

sub throw_fatal_error {
  my ($self, $err) = @_;

  $self->{fatal_error} = $err;

  $self->_throw_error($err);
}

sub _try_to_fill_requests {
  my ($self) = @_;

  return unless exists $self->{worker};
  return unless @{$self->{pending_requests}};

  my $request = shift @{$self->{pending_requests}};

  my $cb = pop @$request;
  $self->{current_cb} = $cb;
  Scalar::Util::weaken($self->{current_cb});

  if ($self->{fatal_error}) {
    $self->_throw_error($self->{fatal_error});
    return;
  }

  my $msg_name = pop @$request;

  $self->_install_timeout_timer;

  $self->{worker}->push_write( packstring => 'w', $request->[0]->pack );

  my $timer;

  if ($self->{log_defer_object}) {
    $timer = $self->{log_defer_object}->timer($msg_name);
  }

  $self->{cmd_handler} = sub {
    my ($handle, $response) = @_;

    undef $timer;

    $response = $self->{rpc_client}->unpack($response);

    if ($self->{log_defer_object} && $response->{ld}) {
      $self->{log_defer_object}->merge($response->{ld});
    }

    if ($response->{cmd} eq 'ok') {
      local $@ = undef;
      $cb->($self, $response->{val});
    } elsif ($response->{cmd} eq 'er') {
      $self->_throw_error($response->{val});
    } else {
      die "Unrecognized response cmd: $response->{cmd}";
    }

    delete $self->{timeout_timer};
    delete $self->{cmd_handler};

    $self->_try_to_fill_requests;
  };

  $self->{worker}->push_read( packstring => 'w', $self->{cmd_handler} );
}

sub DESTROY {
  my ($self) = @_;

  $self->{client}->remove_pending_checkout($self)
    if $self->{client};

  if (exists $self->{worker}) {
    my $worker = $self->{worker};
    delete $self->{client}->{workers_to_checkouts}->{0 + $worker} if $self->{client};
    delete $self->{worker};

    if ($self->{fatal_error} || ($self->{error_occurred} && $self->{client} && !$self->{client}->{dont_refork_after_error})) {
      $self->{client}->destroy_worker($worker) if $self->{client};
      $self->{client}->populate_workers if $self->{client};
    } else {
      $worker->push_write( packstring => 'w', $self->{rpc_client}->terminate->pack );
      $self->{client}->make_worker_available($worker) if $self->{client};
      $self->{client}->try_to_fill_pending_checkouts if $self->{client};
    }
  }

  $self->{pending_requests} = $self->{current_cb} = $self->{timeout_timer} = $self->{cmd_handler} = $self->{rpc_client} = undef;
}


1;
