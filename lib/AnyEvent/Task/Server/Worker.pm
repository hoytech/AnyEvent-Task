package AnyEvent::Task::Server::Worker;

use common::sense;

use AnyEvent::Util;
use Guard;

use POSIX; ## POSIX::_exit is used so we don't unlink the unix socket file created by our parent before the fork
use IO::Select;
use Sereal::Encoder;
use Sereal::Decoder;
use Scalar::Util qw/blessed/;


my $setup_has_been_run;
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
        return if length($buf) < 10;
        POSIX::_exit(1); ## stream is corrupted?
      }

      my $repacked = pack("w", $msg_len);

      $msg_and_prefix_len = length($repacked) + $msg_len;
    }

    return if length($buf) < $msg_and_prefix_len;

    my $input = substr($buf, $msg_and_prefix_len - $msg_len, $msg_len);
    $buf = substr($buf, $msg_and_prefix_len);
    $msg_len = $msg_and_prefix_len = undef;

    $input = Sereal::Decoder::decode_sereal($input, { refuse_objects => 1, refuse_snappy => 1, });

    my $output;
    my $output_meta = {};

    my $cmd = shift @$input;
    my $input_meta = shift @$input;

    if ($cmd eq 'do') {
      my $val;

      local $AnyEvent::Task::Logger::log_defer_object;

      eval {
        if (!$setup_has_been_run) {
          $server->{setup}->();
          $setup_has_been_run = 1;
        }

        $val = scalar $server->{interface}->(@$input);
      };

      my $err = $@;

      $output_meta->{ld} = $AnyEvent::Task::Logger::log_defer_object->{msg}
        if defined $AnyEvent::Task::Logger::log_defer_object;

      if ($err) {
        $err = "$err" if blessed $err;

        $err = "setup exception: $err" if !$setup_has_been_run;

        $output = ['er', $output_meta, $err,];
      } else {
        if (blessed $val) {
          $val = "interface returned object: " . ref($val) . "=($val)";
          $output = ['er', $output_meta, $val,];
        } else {
          $output = ['ok', $output_meta, $val,];
        }
      }

      my $output_sereal = eval { Sereal::Encoder::encode_sereal($output, { croak_on_bless => 1, snappy => 0, }); };

      if ($@) {
        $output = ['er', $output_meta, "error Sereal encoding interface output: $@",];
        $output_sereal = Sereal::Encoder::encode_sereal($output, { no_bless_objects => 1, snappy => 0, });
      }

      my_syswrite($fh, pack("w/a*", $output_sereal));
    } elsif ($cmd eq 'dn') {
      $server->{checkout_done}->();
    } else {
      die "unknown command: $cmd";
    }
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
