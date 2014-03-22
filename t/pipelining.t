use common::sense;

use List::Util;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 1;


## The point of this test is to verify RPC::Pipelined integration.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => {
                 add => sub { $_[0] + $_[1] },
                 mult => sub { $_[0] * $_[1] },
               },
);



my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
             );


my $cv = AE::cv;


my $checkout = $client->checkout;

my $promise = $checkout->add(3, 4);

my $promise2 = $checkout->mult($promise, $promise);

$checkout->add($promise, $promise2, sub {
  my ($checkout, $ret) = @_;
  is($ret, 56, '(3+4)**2 + 7');
  $cv->send;
});

$cv->recv;
