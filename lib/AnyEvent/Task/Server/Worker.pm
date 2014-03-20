package AnyEvent::Task::Server::Worker;

use common::sense;

use AnyEvent::Util;
use RPC::Pipelined::Server;
use Guard;

use POSIX; ## POSIX::_exit is used so we don't unlink the unix socket file created by our parent before the fork
use IO::Select;
use Scalar::Util qw/blessed/;


my $rpc_server;
my $sel;
my $buf;
my $msg_len;
my $msg_and_prefix_len;



sub handle_worker {
  eval {
    handle_worker_wrapped(@_);
  };

  POSIX::_exit(1);
}


sub handle_worker_wrapped {
  my ($server, $fh, $monitor_fh) = @_;

  $rpc_server = RPC::Pipelined::Server->new(
                  interface => $server->{interface},
                  setup => $server->{setup},
                  checkout_done => $server->{checkout_done},
                );

  AnyEvent::Util::fh_nonblocking $fh, 0;
  AnyEvent::Util::fh_nonblocking $monitor_fh, 0;

  $buf = '';

  $sel = IO::Select->new;
  $sel->add($fh, $monitor_fh);

  while(1) {
    my @all_ready = $sel->can_read;

    foreach my $ready (@all_ready) {
      if ($ready == $monitor_fh) {
        ## Lost connection to server
        $sel->remove($monitor_fh);
      } elsif ($ready == $fh) {
        process_data($server, $fh);
      }
    }
  }
}



sub process_data {
  my ($server, $fh) = @_;

  scope_guard { alarm 0 };
  local $SIG{ALRM} = sub { die "hung worker\n" };
  alarm $server->{hung_worker_timeout} if $server->{hung_worker_timeout};

  my $read_rv = sysread $fh, $buf, 1<<16, length($buf);

  if (!defined $read_rv) {
    return if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
    POSIX::_exit(1);
  } elsif ($read_rv == 0) {
    POSIX::_exit(1);
  }

  while(1) {
    if (!defined $msg_len) {
      $msg_len = eval { unpack "w", $buf };

      if (!defined $msg_len) {
        return if length($buf) < 10; ## FIXME: lookup what largest reasonable value is, probably 4-6
        print STDERR "stream is out of sync/corrupted?\n";
        POSIX::_exit(1);
      }

      my $repacked = pack("w", $msg_len);

      $msg_and_prefix_len = length($repacked) + $msg_len;
    }

    return if length($buf) < $msg_and_prefix_len;

    my $input = substr($buf, $msg_and_prefix_len - $msg_len, $msg_len);
    $buf = substr($buf, $msg_and_prefix_len);
    $msg_len = $msg_and_prefix_len = undef;

    my $output = $rpc_server->exec($input);

    my_syswrite($fh, pack("w/a*", $output_sereal));
  }
}



sub my_syswrite {
  my ($fh, $output) = @_;

  while(1) {
    my $rv = syswrite $fh, $output;

    if (!defined $rv) {
      next if $!{EINTR};
      POSIX::_exit(1); ## probably parent died and we're getting broken pipe
    }

    return if $rv == length($output);

    POSIX::_exit(1); ## partial write: probably the socket is set nonblocking
  }
}

1;
