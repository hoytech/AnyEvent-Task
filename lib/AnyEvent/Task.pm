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
