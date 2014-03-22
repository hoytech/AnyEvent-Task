package RPC::Pipelined::Client;

use strict;

use Sereal::Encoder;
use Sereal::Decoder;

use RPC::Pipelined::Promise;


sub new {
  my ($class, %args) = @_;

  my $self = \%args;
  bless $self, $class;

  $self->{calls} = [];

  return $self;
}


sub run {
  my ($self, @args) = @_;

  die "can't begin new message, waiting for response" if $self->{in_progress};
  die "run only supports scalar and void context" if wantarray;

  my $call = { args => \@args, wa => wantarray, };

  $call->{promise} = RPC::Pipelined::Promise->new
    if defined wantarray;

  push @{$self->{calls}}, $call;

  if (defined wantarray) {
    return $call->{promise};
  }

  return;
}

sub pack_msg {
  my ($self) = @_;

  $self->{in_progress} = 1;

  return Sereal::Encoder::encode_sereal({ cmd => 'do', calls => $self->{calls}, });
}

sub unpack_response {
  my ($self, $encoded_response) = @_;

  my $msg = Sereal::Decoder::decode_sereal($encoded_response);

  foreach my $call (@{ $self->{calls} }) {
    if (exists $call->{promise}) {
      $call->{promise}->set_id(shift @{ $msg->{promise_ids} });
    }
  }

  delete $msg->{promise_ids};
  delete $self->{calls};
  $self->{in_progress} = 0;

  return $msg;
}

sub pack_terminate_msg {
  my ($self) = @_;

  return Sereal::Encoder::encode_sereal({ cmd => 'dn', });
}

1;
