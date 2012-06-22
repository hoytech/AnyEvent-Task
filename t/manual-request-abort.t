use common::sense;

use List::Util;
use POSIX;

use Callback::Frame;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 4;


## The point of this test is to verify that if you call a checkout
## object in a non-void context, that destroying the resulting guard
## will immediately terminate the request.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => sub {
                     select undef, undef, undef, 1;
                     die "shouldn't get here";
                   },
);


my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
             );


my $cv = AE::cv;

{
  my $checkout = $client->checkout( timeout => 1, );

  my $guard = $checkout->(frame(code => sub {
    die "checkout was serviced?";
  }, catch => sub {
    my $err = $@;
    print "## error: $err\n";
    ok(1, "error hit");
    ok($err !~ /timed out after/, "no timed out err");
    ok($err !~ /hung worker/, "no hung worker err");
    ok($err =~ /manual request abort/, "manual request abort err");
    $cv->send;
  }));

  $checkout->throw_error("manual request abort");
}

$cv->recv;
