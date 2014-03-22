package RPC::Pipelined::Server;

use strict;

use Sereal::Encoder;
use Sereal::Decoder;
use Data::Rmap qw/rmap_ref/;

use RPC::Pipelined::Promise;


sub new {
  my ($class, %args) = @_;

  my $self = \%args;
  bless $self, $class;

  $self->{promises} = {};
  $self->{next_promise_id} = 0;

  return $self;
}


sub exec {
  my ($self, $msg_encoded) = @_;

  local $RPC::Pipelined::Logger::log_defer_object;
  local $RPC::Pipelined::Promise::current_server = $self;

  my $msg = Sereal::Decoder::decode_sereal($msg_encoded);

  my $output = {};

  if ($msg->{cmd} eq 'do') {
    my $output_val;
    my $output->{promise_ids} = [];

    eval {
      if ($self->{setup} && !$self->{setup_has_been_run}) {
        eval {
          $self->{setup}->();
        };

        die "setup exception: $@" if $@;

        $self->{setup_has_been_run} = 1;
      }

      foreach my $call (@{ $msg->{calls} }) {
        my $args = $call->{args};

        rmap_ref {
          if (ref $_ eq 'RPC::Pipelined::Promise') {
            my $rmap_state = shift;
            delete $rmap_state->{seen}->{0 + $_};
            $_ = $_->{result};
          }
        } $args;

        if ($call == $msg->{calls}->[-1]) {
          $output_val = $self->{interface}->(@$args);
        } elsif (defined $call->{wa}) {
          my $promise = $call->{promise};

          my $id = $promise->{id} = $self->{next_promise_id}++;
          $self->{promises}->{$id} = $promise;
          push @{ $output->{promise_ids} }, $id;

          $promise->{result} = $self->{interface}->(@$args);
        } else {
          $self->{interface}->(@$args);
        }
      }
    };

    my $err = $@;

    $output->{ld} = $RPC::Pipelined::Logger::log_defer_object->{msg}
      if defined $RPC::Pipelined::Logger::log_defer_object;

    if ($err) {
      $output->{cmd} = 'er';
      $output->{val} = $err;
    } else {
      $output->{cmd} = 'ok';
      $output->{val} = $output_val;
    }

    my $output_sereal = eval { Sereal::Encoder::encode_sereal($output); };

    if ($@) {
      $output->{cmd} = 'er';
      $output->{val} = "error Sereal encoding interface output: $@";
      $output_sereal = Sereal::Encoder::encode_sereal($output);
    }

    return $output_sereal;
  } elsif ($msg->{cmd} eq 'dn') {
    $self->{checkout_done}->() if $self->{checkout_done};
    $self->reset;

    return undef;
  } else {
    die "unknown command: $msg->{cmd}";
  }
}


sub reset {
  my ($self) = @_;

  $self->{promises} = {};
}


1;
