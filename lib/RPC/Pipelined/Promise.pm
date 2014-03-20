package RPC::Pipelined::Promise;

use strict;


sub new {
  my ($class, %args) = @_;

  my $self = \%args;
  bless $self, $class;

  return $self;
}


sub set_id {
  my ($self, $id) = @_;

  die "promise already has an id"
    if exists $self->{id};

  $self->{id} = $id;
}


1;
