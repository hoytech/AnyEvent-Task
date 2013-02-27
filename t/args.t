use common::sense;

use List::Util;

use Callback::Frame;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 16;


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
               name => 'MY CLIENT NAME',
             );


my $cv = AE::cv;


{
  $client->checkout->(1, [2], { three => 3, λ => '𝇚' }, sub {
    my ($checkout, $ret) = @_;

    ok(!$@);
    is(@$ret, 3);
    is($ret->[0], 1);
    is($ret->[1]->[0], 2);
    is(ref($ret->[2]), 'HASH');
    is($ret->[2]->{three}, 3);
    is(ord($ret->[2]->{λ}), 0x1D1DA);
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
    ok($@ !~ /setup exception/i);
  }));

  frame(code => sub {
    $client->checkout->error('again, plz die', sub {
      die "should never get here 2";
    });
  }, catch => sub {
    my $trace = shift;
    ok($@ =~ /ERR: again, plz die/);
    ok($trace =~ /MY CLIENT NAME -> error/);

    $cv->send;
  })->();

}


$cv->recv;
