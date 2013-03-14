use common::sense;

use List::Util;

use Callback::Frame;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;
use AnyEvent::Task::Logger;

use Test::More tests => 7;


## The point of this test is to verify Log::Defer integration.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => { normal =>
                   sub {
                     logger->info("hello from", $$);
                     logger->timer("junk");
                     1;
                   },
                 error =>
                   sub {
                     logger->warn("something weird happened");
                     die "uh oh";
                   },
               },
);



my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
             );


my $cv = AE::cv;


my $log_defer_object = Log::Defer->new(sub {
  my $msg = shift;

  is($msg->{logs}->[0]->[2], 'hello from', 'message from client');
  is($msg->{logs}->[1]->[2], 'hello from', 'message from worker');
  isnt($msg->{logs}->[0]->[3], $msg->{logs}->[1]->[3], 'pids are different');
  is($msg->{logs}->[2]->[2], 'after', 'order of msgs ok');
  is($msg->{logs}->[3]->[2], 'something weird happened', 'log messages transfered even on error');

  ok($msg->{timers}->{junk}, 'timer got through');
});

$log_defer_object->info("hello from", $$);

$client->checkout(log_defer_object => $log_defer_object)->normal(sub {
  my ($checkout, $ret) = @_;

  $log_defer_object->info("after");

  $checkout->error(frame(code => sub {
    die "error not thrown?";
  }, catch => sub {
    ok(1, 'error caught');
    $cv->send;
  }));
});


$cv->recv;
