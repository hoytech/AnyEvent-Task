package AnyEvent::Task;

use common::sense;

our $VERSION = '0.1';


1;



=head1 NAME

AnyEvent::Task - Distributed task management infrastructure

=head1 SYNOPSIS 1: PASSWORD HASHING

=head2 Server

    use AnyEvent::Task;
    use Authen::Passphrase::BlowfishCrypt;

    my $dev_urandom;
    my $server = AnyEvent::Task::Server->new(
                   listen => ['unix/', '/tmp/anyevent-task.socket'],
                   setup => sub {
                     open($dev_urandom, "/dev/urandom") || die "open urandom: $!";
                   },
                   interface => {
                     hash_passwd => sub {
                       my ($plaintext_passwd) = @_;
                       read($dev_urandom, my $salt, 16) == 16 || die "bad read from urandom";
                       return Authen::Passphrase::BlowfishCrypt->new(cost => 10,
                                                                     salt => $salt,
                                                                     passphrase => $plaintext_passwd)
                                                               ->as_crypt;

                     },
                     verify_passwd => sub {
                       my ($crypted_passwd, $plaintext_passwd) = @_;
                       return Authen::Passphrase::BlowfishCrypt->from_crypt($crypted_passwd)
                                                               ->match($plaintext_passwd);
                     },
                   },
                 );

    $server->run;


=head2 Client

    use AnyEvent::Task::Client;

    my $client = AnyEvent::Task::Client->new(
                   connect => ['unix/', '/tmp/anyevent-task.socket'],
                 );

    my $crypter; $crypter = $client->checkout(
                              timeout => 5,
                              on_error => sub {
                                            print STDERR "password hashing failed: $@";
                                            undef $crypter;
                                          },
                            );

    $crypter->hash_passwd('secret',
      sub {
        my ($crypter, $crypted_passwd) = @_;
        die "crypter died: $@" if defined $@;

        print "Hashed password is $crypted_passwd\n";

        $crypter->verify_passwd($crypted_passwd,
          sub {
            my ($crypter, $result) = @_;
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

    $server->run;


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
        die "DB lookup failed: $@" if defined $dbh;
        print "User's email is $row->{email}\n";
        ## Use same $dbh here if using transactions
      });

=head1 DESCRIPTION

The synopsis makes this module sounds much more complicated than it actually is. L<AnyEvent::Task> is a fork-on-demand but persistent-worker-process server (L<AnyEvent::Task::Server>) combined with an asynchronous interface to a request queue and pooled-worker client (L<AnyEvent::Task::Client>). Both client and server are of course built with L<AnyEvent> because it's awesome. However, workers don't typically use AnyEvent (yet).

A server is started with C<< AnyEvent::Task::Server->new >>. This should at least be passed the C<listen> and C<interface> arguments. Keep the returned server object around for as long as you want the server to be running. A C<setup> coderef can be passed in to run some code when a new worker is forked. C<interface> is the code that should handle each request. See the interface section below for its specification.

A client is started with C<< AnyEvent::Task::Client->new >>. You only need to pass C<connect> to this. Keep the returned client object around as long as you wish the client to be connected.

After both the server and client are initialized, each process must enter AnyEvent's "main loop" in some way, possibly just C<< AE::cv->recv >>.

In the client process, you may call the C<checkout> method on the client object. This checkout object can be used to run code on a remote worker process in a non-blocking manner. The C<checkout> method doesn't require any arguments, but C<timeout> and C<on_error> are recommended.

You can treat a checkout object as an object that proxies its method calls to a worker process or a function that does the same. You pass the arguments to these method calls as an argument to the checkout object, followed by a callback as the last argument. This callback will be called once the worker process has returned the results. This callback will normally be passed two arguments, the checkout object and the return value. In the event of an exception thrown inside the worker, only the checkout object will be passed in and L<$@> will be set to the error message.



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

The second format possible for C<interface> is a hash ref. This is a minor convenience format for method dispatch where the method invoked on the checkout object is the key to which coderef to be run in the worker:

    interface => {
      method1 => sub {
        my (@args) = @_;
      },
      method2 => sub {
        my (@args) = @_;
      },
    },

Note that since the protocol between the client and the worker process is JSON-based, all arguments and return values must be serializable to JSON (most perl scalars like strings and a limited range of numerical types, and hash/list constructs with no cyclical references).

A future (backwards compatible) protocol may use L<Storable> or something else as the RPC, although note that you can already serialize an object with Storable manually, send the resulting string over the existing protocol, and the deserialize it in the worker.




=head1 STARTING THE SERVER

Technically, running the server and the client in the same process is possible, but is highly discouraged since the server will C<fork()> when the client desires a worker process. When this happens, all descriptors in use by the client and server are duped into the worker process which will interfere with cleaning up (closing) these descriptors in the client. So after a C<fork()> the worker should close all descriptors except for its connection to the client and a pipe to the server which is used in order to detect a server shutdown (and then gracefully exit).

Since it's more of a bother than it's worth to run the server and the client in the same process, there is an alternate server constructor, C<AnyEvent::Task::Server::fork_task_server>. It can be passed the same arguments as the regular C<new> constructor. The only difference is that it will fork before it does so and the child process will be the server. Since this constructor forks, it is important that you not install any AnyEvent watchers (including creating AnyEvent::Task clients) before calling this alternate server constructor because this constructor requires using AnyEvent in the child process as well as the parent (see the usual caveats about forking AnyEvent applications in the AnyEvent docs).

If C<AnyEvent::Task::Server::fork_task_server> is called in a void context, then the reference to a pipe connected to the server pushed onto C<@AnyEvent::Task::Server::children_sockets>. Otherwise, the pipe and the server's PID are returned. Closing the pipe (or killing the PID) will terminate the worker.



=head1 DESIGN

The first thing to realize is that each client maintains a "pool" of connections to worker processes. Every time a checkout is issued, it is placed into a first-come, first-serve queue. Once a worker process becomes available, it is associated with that checkout until that checkout is garbage collected. Each checkout also maintains a queue of requests, so that as soon as this worker process is allocated, the requests are filled also on a first-come, first-server basis.

C<timeout> and C<on_error> can be passed as arguments to C<checkout>. Once a request is queued up on that checkout, a timer of C<timout> seconds (default is 30, undef means infinity) is started. If the request completes during this timeframe, the timer is cancelled. If the timer expires however, the worker connection is terminated and the C<on_error> callback is invoked with C<$@> set to the reason for the error. Note that the C<on_error> callback is only invoked for timeout errors, protocol errors, and manual termination of the checkout. Regular errors that occur when the worker process code throws an exception are returned to the callback coderef as described above.

Note that since timeouts are associated with a checkout, the client process can be started before the server and as long as the server is started within C<timeout> seconds, no requests will be lost. The client will continually try to acquire worker processes until a server is available, and once one is available it will attempt to fill all queued checkouts. Because of this, you should usually use C<on_error> to handle timeout errors.

Additionally, because of checkout queuing the maximum number of worker processes a client should attempt to obtain can be limited with the C<max_workers> argument when creating a client object. If there are more live checkouts than C<max_workers>, the remaining checkouts will have to wait until one of the other checkouts becomes available. Note that typically a request is immediately issued as soon as the checkout is created so the timer generally starts at checkout creation time, meaning that some checkouts may never be serviced if the system can't handle the load (instead the checkout's C<on_error> handler will be called with a timeout error).

The C<min_workers> argument can be used to "pre-fork" some "hot-standby" worker processes when creating the client. The default is 2 though note that this may change (FIXME: consider if the default should be 0).


=head1 COMPARISON WITH HTTP

Why a custom protocol, client, and server? Can't we just use something like HTTP?

Yes and no.

AnyEvent::Task clients send discrete messages and receive ordered, discrete replies from workers, much like HTTP. The AnyEvent::Task protocol can be extended in a backwards compatible manner like HTTP. AnyEvent::Task communication can be pipelined (and possibly in the future even compressed), like HTTP.

AnyEvent::Task servers (currently) all obey a very specific implementation policy: They are kind of like CGI servers in that each process is guaranteed to be handling only one connection at once so it can perform blocking operations without worrying about holding up other connections.

Actually, since a single process can handle many requests in a row, the AnyEvent::Task server is more like a FastCGI server, except that if a client holds a checkout, it is guaranteed an exclusive lock on that process. With a FastCGI server, it is assumed that requests are stateless so you aren't necessarily sure you'll get the same process for two consecutive requests. In fact, if an error is thrown in the FastCGI handler, you may never get the same process back again (which you might like to have for accessing error states like the DBI errstr and/or recovering from the error).

Probably the most fundamental difference between the AnyEvent::Task protocol and HTTP is that in AnyEvent::Task, the client is the dominant, driving process whereas in HTTP it is the server. In AnyEvent::Task, the client manages the worker pool and the client decides when the worker process should terminate or whether it should be returned to its worker pool. A worker can request a shutdown (as it does when its parent server dies), but can't outright refuse to stop accepting commands until the client is good and ready.

The client decides the timeout for each checkout, and different clients can have different timeouts while connecting to the same server. The client even decides how many minimum and maximum workers it will run at once. The server is really just a simple on-demand-forking server and most of the sophistication is done in the asynchronous client.

=cut






__END__

PROTOCOL

Normal request:
  client -> worker
    ['do', **ARGS**]
         <-
    ['ok', *RESULT*, {*META*}]
         OR
    ['er', *ERR_MSG*, {*META*}]


Transaction done:
  client -> worker
    ['dn']
         <-
    ['dn', {*META}]


Client wants to shutdown:
    just shuts down connection


Worker wants to shutdown:
  worker -> client
    ['sk']
         <-
    (client now closes connection)
