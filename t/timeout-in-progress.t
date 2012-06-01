use common::sense;

use List::Util;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 1;


## The point of this test is to ensure that checkouts are timed out
## when the worker process takes too long.


AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => sub {
                     select undef, undef, undef, 0.4;
                     die "shouldn't get here";
                   },
);


my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
             );


my $cv = AE::cv;

{
  my $checkout = $client->checkout(
                            timeout => 0.2,
                            on_error => sub {
                              print "## on_error: $@\n";
                              ok(1, "timeout hit");
                              $cv->send;
                            });

  $checkout->(sub {
    ok(0, "checkout was serviced?");
  });

  $cv->recv;
}
