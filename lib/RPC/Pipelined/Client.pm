package RPC::Pipelined::Server;

use strict;

use Sereal::Encoder;
use Sereal::Decoder;


sub new {
  my ($class, %args);

  my $self = \%args;
  bless $self, $class;

  $self->{calls} = [];

  return $self;
}


sub run {
  my ($self, @args) = @_;

  die "run only supports scalar and void context" if wantarray;

  my $call = { args => \@args, };

  $call->{promise} = RPC::Pipelined::Promise->new
    if defined wantarray;

  push @{$self->{calls}}, { wa => wantarray, ar => \@args, };

  if (defined wantarray) {
    return RPC::Pipelined::Promise->new;
  }

  return;
}

sub pack_msg {
  my ($self) = @_;
}

sub unpack_response {
  my ($self, $encoded_response) = @_;
}

sub pack_terminate_msg {
  my ($self) = @_;
}

1;
