use common::sense;

use List::Util;
use Callback::Frame;

use AnyEvent::Strict;
use AnyEvent::Util;
use AnyEvent::Task::Server;
use AnyEvent::Task::Client;

use Test::More tests => 7;


## The point of this test is to verify that a checkout's methods can
## still be called after a regular error is thrown, perhaps to access
## error states or to rollback a transaction. This test also verifies
## the refork_after_error client option kills off the worker process
## and creates a new one if it threw an error was thrown in its lifetime.



AnyEvent::Task::Server::fork_task_server(
  listen => ['unix/', '/tmp/anyevent-task-test.socket'],
  interface => {
    get_pid => sub { return $$ },
    throw => sub { my ($err) = @_; die $err; },
  },
);



my $client = AnyEvent::Task::Client->new(
               connect => ['unix/', '/tmp/anyevent-task-test.socket'],
               max_workers => 1,
               refork_after_error => 1,
             );


my $cv = AE::cv;

my $pid;
{
  my $checkout = $client->checkout();

  $checkout->get_pid(sub {
    my ($checkout, $ret) = @_;
    $pid = $ret;

    like($pid, qr/^\d+$/, "got PID");

    $checkout->get_pid(sub {
      my ($checkout, $ret) = @_;
      is($pid, $ret, "PID didn't change in same checkout");

      $checkout->throw("BLAH", frame(code => sub {
        die "throw method didn't return error";
      }, catch => sub {
        my $err = $@;
        like($err, qr/BLAH/, "caught BLAH error");

        $checkout->get_pid(sub {
          my ($checkout, $ret) = @_;
          is($pid, $ret, "PID didn't change even after error");

          $checkout->throw("OUCH", frame(code => sub {
            die "throw method didn't return error 2";
          }, catch => sub {
            my $err = $@;
            like($err, qr/OUCH/, "caught OUCH error");
 
            $checkout->get_pid(sub {
              my ($checkout, $ret) = @_;
              is($pid, $ret, "PID didn't change even after second error");
            });
          }));
        });
      }));
    });
  });
}


{
  my $checkout = $client->checkout();

  $checkout->get_pid(sub {
    my ($checkout, $ret) = @_;
    isnt($ret, $pid, "new worker was created since previous checkout had an error and we set refork_after_error");

    $cv->send;
  });
}


$cv->recv;
