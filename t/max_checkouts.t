use common::sense;

use List::Util;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 2;


## The point of this test is to verify that workers are restarted
## after they handle max_checkouts checkouts.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => sub {
                     return $$;
                   },
);



my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
               max_workers => 1,
               max_checkouts => 2,
             );


my $cv = AE::cv;

my $pid;

{
  $client->checkout->(sub {
    my ($checkout, $ret) = @_;
    $pid = $ret;
  });

  $client->checkout->(sub {
    my ($checkout, $ret) = @_;
    ok($pid == $ret);
  });

  $client->checkout->(sub {
    my ($checkout, $ret) = @_;
    ok($pid != $ret);
    $cv->send;
  });
}


$cv->recv;
