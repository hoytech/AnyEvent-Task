use common::sense;

use List::Util;

use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 2;


## The point of this test is to verify RPC::Pipelined integration when the
## callback to be invoked is a method call on a promise (which requires some
## special-casing under the hood).

## It also verifies the invocation of a sub using the default interface.


{
  package Mock::Obj;

  sub new {
    my ($class, %arg) = @_;
    bless \%arg, $class;
  }

  sub get {
    my ($self, $val) = @_;
    return uc $val;
  }
}


AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
);



my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
             );


my $cv = AE::cv;


my $checkout = $client->checkout;

my $upper_caser = $checkout->('Mock::Obj', 'new');

$upper_caser->get('ping', sub {
  my ($checkout, $ret) = @_;
  is($ret, "PING", "upper cased OK");
});




sub my_uc {
  return uc($_[0]);
}

$checkout->(undef, __PACKAGE__.'::my_uc', 'rofl', sub {
  my ($checkout, $ret) = @_;
  is($ret, "ROFL", "invoked my_uc OK");
  $cv->send;
});



$cv->recv;
