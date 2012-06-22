use common::sense;

use List::Util;
use POSIX;

use Callback::Frame;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 3;


## The point of this test is to ensure that when a worker connection dies
## suddenly, ie with POSIX::_exit(), an appropriate error is promptly raised
## in the callback's dynamic environment.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => sub {
                     select undef, undef, undef, 0.1;
                     POSIX::_exit(1);
                     die "shouldn't get here";
                   },
);


my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
             );


my $cv = AE::cv;

{
  my $checkout = $client->checkout( timeout => 1, );

  $checkout->(frame(code => sub {
    die "checkout was serviced?";
  }, catch => sub {
    my $err = $@;
    print "## on_error: $err\n";
    ok(1, "error hit");
    ok($err !~ /timed out after/, "no timed out err");
    ok($err =~ /worker connection suddenly died/, "sudden death err");
    $cv->send;
  }));
}

$cv->recv;
