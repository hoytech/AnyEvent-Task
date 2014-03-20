package RPC::Pipelined::Server;

use strict;

use Sereal::Encoder;
use Sereal::Decoder;


sub new {
  my ($class, %args);

  my $self = \%args;
  bless $self, $class;

  return $self;
}


sub exec {
  my ($self, $msg_encoded) = @_;

  my $msg = Sereal::Decoder::decode_sereal($msg_encoded, { refuse_objects => 1, refuse_snappy => 1, });

  my $output = {};

  if ($msg->{cmd} eq 'do') {
    my $val;

    local $RPC::Pipelined::Logger::log_defer_object;

    eval {
      if ($self->{setup} && !$self->{setup_has_been_run}) {
        $self->{setup}->();
        $self->{setup_has_been_run} = 1;
      }

      $val = $server->interface($msg);
    };

    my $err = $@;

    $output->{ld} = $RPC::Pipelined::Logger::log_defer_object->{msg}
      if defined $RPC::Pipelined::Logger::log_defer_object;

    if ($err) {
      $err = "$err" if blessed $err;

      $output->{cmd} = 'er';
      $output->{val} = $err;
    } else {
      if (blessed $val) {
        $output->{cmd} = 'er';
        $output->{val} = "interface returned object: " . ref($val) . "=($val)";
      } else {
        $output->{cmd} = 'ok';
        $output->{val} = $val;
      }
    }

    my $output_sereal = eval { Sereal::Encoder::encode_sereal($output, { croak_on_bless => 1, snappy => 0, }); };

    if ($@) {
      $output->{cmd} = 'er';
      $output->{val} = "error Sereal encoding interface output: $@";
      $output_sereal = Sereal::Encoder::encode_sereal($output, { no_bless_objects => 1, snappy => 0, });
    }

    return $output_sereal;
  } elsif ($msg->{cmd} eq 'dn') {
    $self->{checkout_done}->() if $self->{checkout_done};
    $rpc_server->reset;
  } else {
    die "unknown command: $msg->{cmd}";
  }
}


1;
