use common::sense;

use List::Util;

use Callback::Frame;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 12;


## The point of this test is to verify that arguments, errors, and
## return values are passed correctly between client and server.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => sub {
                     die "ERR: $_[1]" if $_[0] eq 'error';
                     return \@_;
                   },
);



my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
               max_workers => 1,
             );


my $cv = AE::cv;


{
  $client->checkout->(1, [2], { three => 3, }, sub {
    my ($checkout, $ret) = @_;

    ok(!$@);
    ok(@$ret == 3);
    ok($ret->[0] == 1);
    ok($ret->[1]->[0] == 2);
    ok(ref($ret->[2]) eq 'HASH');
    ok($ret->[2]->{three} eq 3);
  });

  $client->checkout->some_method(1, sub {
    my ($checkout, $ret) = @_;

    ok(!$@);
    ok(@$ret == 2);
    ok($ret->[0] eq 'some_method');
    ok($ret->[1] == 1);
  });

  $client->checkout->error('die please', frame(code => sub {
    die "should never get here";
  }, catch => sub {
    ok($@);
    ok($@ =~ /ERR: die please/);

    $cv->send;
  }));
}


$cv->recv;
