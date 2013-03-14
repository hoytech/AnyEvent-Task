package AnyEvent::Task;

use common::sense;

our $VERSION = '0.700';


1;


__END__

=head1 NAME

AnyEvent::Task - Client/server-based asynchronous worker pool

=head1 SYNOPSIS 1: PASSWORD HASHING

=head2 Server

    use AnyEvent::Task::Server;
    use Authen::Passphrase::BlowfishCrypt;

    my $dev_urandom;
    my $server = AnyEvent::Task::Server->new(
                   listen => ['unix/', '/tmp/anyevent-task.socket'],
                   setup => sub {
                     open($dev_urandom, "/dev/urandom") || die "open urandom: $!";
                   },
                   interface => {
                     hash => sub {
                       my ($plaintext) = @_;
                       read($dev_urandom, my $salt, 16) == 16 || die "bad read from urandom";
                       return Authen::Passphrase::BlowfishCrypt->new(cost => 10,
                                                                     salt => $salt,
                                                                     passphrase => $plaintext)
                                                               ->as_crypt;

                     },
                     verify => sub {
                       my ($crypted, $plaintext) = @_;
                       return Authen::Passphrase::BlowfishCrypt->from_crypt($crypted)
                                                               ->match($plaintext);
                     },
                   },
                 );

    $server->run; # or AE::cv->recv


=head2 Client

    use AnyEvent::Task::Client;

    my $client = AnyEvent::Task::Client->new(
                   connect => ['unix/', '/tmp/anyevent-task.socket'],
                 );

    my $checkout; $checkout = $client->checkout( timeout => 5, );

    $checkout->hash('secret',
      sub {
        my ($checkout, $crypted) = @_;

        print "Hashed password is $crypted\n";

        $checkout->verify($crypted,
          sub {
            my ($checkout, $result) = @_;
            print "Verify result is $result\n":
          });
      });




=head1 SYNOPSIS 2: DBI


=head2 Server

    use AnyEvent::Task::Server;
    use DBI;

    my $dbh;

    my $server = AnyEvent::Task::Server->new(
                   listen => ['unix/', '/tmp/anyevent-task.socket'],
                   setup => sub {
                     $dbh = DBI->connect(...);
                   },
                   interface => sub {
                     my ($method, @args) = @_;
                     $args[0] = $dbh->prepare_cached($args[0]) if defined $args[0];
                     $dbh->$method(@args);
                   },
                 );

    $server->run; # or AE::cv->recv


=head2 Client

    use AnyEvent::Task::Client;

    my $dbh_pool = AnyEvent::Task::Client->new(
                     connect => ['unix/', '/tmp/anyevent-task.socket'],
                   );

    my $username = 'jimmy';

    my $dbh = $dbh_pool->checkout;

    $dbh->selectrow_hashref(q{ SELECT email FROM user WHERE username = ? },
                            undef, $username,
      sub {
        my ($dbh, $row) = @_;
        print "User's email is $row->{email}\n";
        ## Use same $dbh here if using transactions
      });

=head1 DESCRIPTION

B<WARNING:> The above client examples don't implement error handling. See the L<ERROR HANDLING> section for details on how to add this.

The synopsis makes this module sounds much more complicated than it actually is. L<AnyEvent::Task> is a fork-on-demand but persistent-worker server (L<AnyEvent::Task::Server>) combined with an asynchronous interface to a request queue and pooled-worker client (L<AnyEvent::Task::Client>). Both client and server are of course built with L<AnyEvent> because it's awesome. However, workers can't use AnyEvent (yet).

A server is started with C<< AnyEvent::Task::Server->new >>. This should at least be passed the C<listen> and C<interface> arguments. Keep the returned server object around for as long as you want the server to be running. C<interface> is the code that should handle each request. See the interface section below for its specification. A C<setup> coderef can be passed in to run some code when a new worker is forked. A C<checkout_done> coderef can be passed in to run some code whenever a checkout is released (see below).

A client is started with C<< AnyEvent::Task::Client->new >>. You only need to pass C<connect> to this. Keep the returned client object around as long as you wish the client to be connected.

After both the server and client are initialised, each process must enter AnyEvent's "main loop" in some way, possibly just C<< AE::cv->recv >>.

In the client process, you may call the C<checkout> method on the client object. This checkout object can be used to run code on a remote worker process in a non-blocking manner. The C<checkout> method doesn't require any arguments, but C<timeout> is recommended.

You can treat a checkout object as an object that proxies its method calls to a worker process or a function that does the same. You pass the arguments to these method calls as an argument to the checkout object, followed by a callback as the last argument. This callback will be called once the worker process has returned the results. This callback will normally be passed two arguments, the checkout object and the return value. In the event of an exception thrown, an error is raised in the dynamic context of the callback (see the L<ERROR HANDLING> section).




=head1 DESIGN

Each client maintains a "pool" of connections to worker processes. Every time a checkout is issued, it is placed into a first-come, first-serve queue. Once a worker process becomes available, it is associated with that checkout until that checkout is garbage collected. Each checkout also maintains a queue of requests, so that as soon as this worker process is allocated, the requests are filled also on a first-come, first-server basis.

C<timeout> can be passed as a keyword argument to C<checkout>. Once a request is queued up on that checkout, a timer of C<timout> seconds (default is 30, undef means infinity) is started. If the request completes during this timeframe, the timer is cancelled. If the timer expires however, the worker connection is terminated and an exception is thrown in the dynamic context of the callback (see the L<ERROR HANDLING> section).

Note that since timeouts are associated with a checkout, the client process can be started before the server and as long as the server is started within C<timeout> seconds, no requests will be lost. The client will continually try to acquire worker processes until a server is available, and once one is available it will attempt to fill all queued checkouts.

Because of checkout queuing, the maximum number of worker processes a client will attempt to obtain can be limited with the C<max_workers> argument when creating a client object. If there are more live checkouts than C<max_workers>, the remaining checkouts will have to wait until one of the other workers becomes available. Because of timeouts, some checkouts may never be serviced if the system can't handle the load (those requests should be sent "service temporarily unavailable" errors).

The C<min_workers> argument can be used to pre-fork "hot-standby" worker processes when creating the client. The default is 2 though note that this may change to 0 in the future.





=head1 STARTING THE SERVER

Technically, running the server and the client in the same process is possible, but is highly discouraged since the server will C<fork()> when the client desires a worker process. In this case, all descriptors in use by the client would be duped into the worker process and the worker would have to close all the extra- descriptors created by the client. Also, forking a busy client may be memory-inefficient.

Since it's more of a bother than it's worth to run the server and the client in the same process, there is an alternate server constructor, C<AnyEvent::Task::Server::fork_task_server>. It can be passed the same arguments as the regular C<new> constructor:

    ## my ($keepalive_pipe, $pid) =
    AnyEvent::Task::Server::fork_task_server(
      listen => ['unix/', '/tmp/anyevent-task.socket'],
      interface => sub {
                         return "Hello from PID $$";
                       },
    );

The only differences between this and the regular constructor is that this will fork a process which becomes the server, and that it will install a "keep-alive" pipe between the server and the client. This keep-alive pipe will be used by the server to detect when the client/parent process exits.

If C<AnyEvent::Task::Server::fork_task_server> is called in a void context, then the reference to this keep-alive pipe is pushed onto C<@AnyEvent::Task::Server::children_sockets>. Otherwise, the keep-alive pipe and the server's PID are returned. Closing the pipe will terminate the worker gracefully. Killing the PID will attempt to terminate the worker immediately.

Since this constructor forks and requires using AnyEvent in both the parent and child processes, it is important that you not install any AnyEvent watchers before calling it. The usual caveats about forking AnyEvent applications apply (see AnyEvent docs).





=head1 INTERFACE

There are two formats possible for the C<interface> option when creating a server. The first (and most general) is a coderef. This coderef will be passed the list of arguments that were sent when the checkout was called in the client process (without the trailing callback of course).

As described above, you can use a checkout object as a coderef or as an object with methods. If the checkout is invoked as an object, the method name is prepended to the arguments passed to C<interface>:

    interface => sub {
      my ($method, @args) = @_;
    },

If the checkout is invoked as a coderef, method is omitted:

    interface => sub {
      my (@args) = @_;
    },

The second format possible for C<interface> is a hash ref. This is a minor short-cut for method dispatch where the method invoked on the checkout object is the key to which coderef to be run in the worker:

    interface => {
      method1 => sub {
        my (@args) = @_;
      },
      method2 => sub {
        my (@args) = @_;
      },
    },

Note that since the protocol between the client and the worker process is JSON-based, all arguments and return values must be serializable to JSON. This includes most perl scalars like strings, a limited range of numerical types, and hash/list constructs with no cyclical references.

A future backwards compatible RPC protocol may use L<Storable> or something else, although note that you can already serialise an object with Storable manually, send the resulting string over the existing protocol, and then deserialise it in the worker.








=head1 LOGGING

Because workers run in a separate process, they can't directly use logging contexts in the client process. That is why this module is integrated with L<Log::Defer>.

A L<Log::Defer> object is created on demand in the worker process and once the worker operation is done an operation, any messages in the object will be extracted and sent back to the client. The client then merges this into another Log::Defer object that is passed in when creating a checkout.

In your server code, use L<AnyEvent::Task::Logger>. It export the function C<logger> which returns a L<Log::Defer> object:

    use AnyEvent::Task::Server;
    use AnyEvent::Task::Logger;

    AnyEvent::Task::Server->new(
      listen => ['unix/', '/tmp/anyevent-task-test.socket'],
      interface => sub {
        logger->info('about to compute some operation');
        {
          my $timer = logger->timer('computing some operation');
          select undef,undef,undef, 1; ## sleep for 1 second
        }
      },
    )->run;


Note: Portable server code should not call C<sleep> because on some systems it will interfere with the recoverable worker timeout feature implemented with C<SIGALRM>.


In your client code, pass a Log::Defer object in when you create a checkout:

    use AnyEvent::Task::Client;
    use Log::Defer;

    my $client = AnyEvent::Task::Client->new(
                   connect => ['unix/', '/tmp/anyevent-task-test.socket'],
                 );

    my $log_defer_object = Log::Defer->new(sub {
                                             my $msg = shift;
                                             use Data::Dumper; ## or whatever
                                             print Dumper($msg);
                                           });

    $log_defer_object->info('going to compute some operation in a worker');

    my $checkout = $client->checkout(log_defer_object => $log_defer_object);

    my $cv = AE::cv;

    $checkout->(sub {
      $log_defer_object->info('finished some operation');
      $cv->send;
    });

    $cv->recv;


When run, the above client will print something like this:


    $VAR1 = {
          'start' => '1363232705.96839',
          'end' => '1.027309',
          'logs' => [
                      [
                        '0.000179',
                        30,
                        'going to compute some operation in a worker'
                      ],
                      [
                        '0.023881061050415',
                        30,
                        'about to compute some operation'
                      ],
                      [
                        '1.025965',
                        30,
                        'finished some operation'
                      ]
                    ],
          'timers' => {
                        'computing some operation' => [
                                                        '0.024089061050415',
                                                        '1.02470206105041'
                                                      ]
                      }
        };




=head1 ERROR HANDLING

If you expected some operation to throw an exception, in a synchronous program you might do something like this:

    my $crypted;

    eval {
      $crypted = hash('secret');
    };

    if ($@) {
      say "hash failed: $@";
    } else {
      say "hashed password is $crypted";
    }

But in an asynchronous program, typically the C<hash> operation would initiate some kind of asynchronous operation and then return immediately. The error might come back at any time in the future, in which case you need a way to map the exception that is thrown back to the C<$conn> object.

AnyEvent::Task accomplishes this mapping with L<Callback::Frame>. For example:

    use Callback::Frame;

    frame(code => sub {
      $client->checkout->hash('secret', sub {
        my ($checkout, $crypted) = @_;
        say "Hashed password is $crypted";
      });
    }, catch => sub {
      my $back_trace = shift;
      say "Error is: $@";
      say "Full back-trace: $back_trace";
    })->();

Why not just an error callback supplied by AnyEvent::Task?

Callback::Frame lets you pass dynamic state (like error handlers and dynamic variables) through nested chains of callbacks even if some of those callbacks don't support about your error handling system.

Additionally, Callback::Frame provides a error handler stack so you can have nested error handlers (similar to nested C<eval>s). This is useful when you wish to have a top-level "bail-out" error handler and also nested error handlers that know how to retry or recover from an error in an async sub-operation.

Callback::Frame is not tied to AnyEvent::Task, AnyEvent or any other async framework and can be used with almost all most callback-based libraries. When using AnyEvent::Task however, your libraries must be L<AnyEvent> compatible.

Instead of passing C<sub { ... }> into libraries, pass in C<fub { ... }>. When invoked, the wrapped callback will first re-establish any error handlers installed with C<frame>, and then run your actual callback code. Note that it's important that all callbacks be created with C<fub> (or C<frame>) even if you don't expect them to fail so that the dynamic context is preserved for nested callbacks that might.

If you have a callback and wish to raise an exception inside its dynamic context, use C<existing_frame>:

    frame(existing_frame => $current_cb,
          code => sub {
      die $err;
    })->();

In addition to errors that occur while running your callbacks, L<AnyEvent::Task> uses this feature of L<Callback::Frame> to throw errors if the worker process dies or times out.





=head1 COMPARISON WITH HTTP

Why a custom protocol, client, and server? Can't we just use something like HTTP?

It depends.

AnyEvent::Task clients send discrete messages and receive ordered, discrete replies from workers, much like HTTP. The AnyEvent::Task protocol can be extended in a backwards compatible manner like HTTP. AnyEvent::Task communication can be pipelined (and possibly in the future even compressed) like HTTP.

AnyEvent::Task servers (currently) all obey a very specific implementation policy: They are kind of like CGI servers in that each process is guaranteed to be handling only one connection at once so it can perform blocking operations without worrying about holding up other connections.

Actually, since a single process can handle many requests in a row, the AnyEvent::Task server is more like a FastCGI server except that while a client holds a checkout it is guaranteed an exclusive lock on that process. With a FastCGI server it is assumed that requests are stateless so you can't necessarily be sure you'll get the same process for two consecutive requests. In fact, if an error is thrown in the FastCGI handler you may never get the same process back again, preventing you from being able to recover from the error or at least collect process state for logging reasons.

The most fundamental difference between the AnyEvent::Task protocol and HTTP is that in AnyEvent::Task the client is the dominant protocol orchestrator whereas in HTTP it is the server.

In AnyEvent::Task, the client manages the worker pool and the client decides if/when the worker process should terminate. In the normal case, a client will just return the worker to its worker pool. A worker can request a shutdown when its parent server dies but can't outright refuse to accept commands until the client is good and ready.

Client process can be started and checkouts can be obtained before the server is even started. The client will continue to try to obtain worker processes until either the server starts or the checkout's timeout period elapses.

The client decides the timeout for each checkout and different clients can have different timeouts while connecting to the same server.

The client even decides how many minimum and maximum workers it requires at once. The server is really just a simple fork-on-demand server and most of the sophistication is in the asynchronous client.




=head1 SEE ALSO

L<The AnyEvent::Task github repo|https://github.com/hoytech/AnyEvent-Task>

AnyEvent::Task is integrated with L<Callback::Frame>. In order to handle exceptions in a meaningful way, you will need to use this module.

There's about a million CPAN modules that do similar things.

This module is designed to be used in a non-blocking, process-based program on unix. Depending on your exact requirements you might find something else useful: L<Parallel::ForkManager>, L<Thread::Pool>, an HTTP server of some kind, &c.

If you're into AnyEvent, L<AnyEvent::DBI> and L<AnyEvent::Worker> (based on AnyEvent::DBI), and L<AnyEvent::ForkObject> send and receive commands from worker processes similar to this module. L<AnyEvent::Worker::Pool> also has an implementation of a worker pool. L<AnyEvent::Gearman> can interface with Gearman services.

If you're into POE there is L<POE::Component::Pool::DBI>, L<POEx::WorkerPool>, L<POE::Component::ResourcePool>, L<POE::Component::PreforkDispatch>, L<Cantella::Worker>, &c.



=head1 BUGS

This module is still being developed although the interface should be mostly stable.




=head1 AUTHOR

Doug Hoyte, C<< <doug@hcsw.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012-2013 Doug Hoyte.

This module is licensed under the same terms as perl itself.

=cut




__END__




PROTOCOL

Normal request:
  client -> worker
    ['do', {META}, @ARGS]
         <-
    ['ok', {META}, $RESULT]
         OR
    ['er', {META}, $ERR_MSG]


Transaction done:
  client -> worker
    ['dn', {META}]


Client wants to shutdown:
    just shuts down connection






TODO

! need test for checkout_done feature

servers must wait() on all their children before terminating
  - support relinquishing accept() socket during this period?

Manual termination of checkouts
  - Write test to ensure callback isn't run after timing out
    or manually terminating checkouts

Document hung_worker_timeout

min_workers == 0 doesn't work.. always starts up 1 worker

max checkout queue size
