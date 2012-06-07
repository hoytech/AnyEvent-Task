package AnyEvent::Task::Server::Worker;

use common::sense;

use AnyEvent::Util;

use POSIX;
use IO::Select;
use JSON::XS;
use Scalar::Util qw/blessed/;


my $json;
my $sel;
my $attempt_graceful_stop;


sub handle_worker {
  my ($interface, $fh, $monitor_fh) = @_;

  AnyEvent::Util::fh_nonblocking $fh, 0;
  AnyEvent::Util::fh_nonblocking $monitor_fh, 0;

  $json = new JSON::XS;

  $sel = IO::Select->new;
  $sel->add($fh, $monitor_fh);

  while(1) {
    my @all_ready = $sel->can_read;

    foreach my $ready (@all_ready) {
      if ($ready == $monitor_fh) {
        $attempt_graceful_stop = 1;
        $sel->remove($monitor_fh);
        my_syswrite($fh, encode_json(['sk']));
      } elsif ($ready == $fh) {
        process_data($interface, $fh);
      }
    }
  }
}



sub process_data {
  my ($interface, $fh) = @_;

  my $read_rv = sysread $fh, my $buf, 4096;

  ## _exit is used so we don't unlink the unix socket file created by our parent before the fork
  if (!defined $read_rv) {
    return if $!{EINTR};
    POSIX::_exit(1);
  } elsif ($read_rv == 0) {
    POSIX::_exit(1);
  }

  for my $input ($json->incr_parse($buf)) {
    my $output;
    my $meta = {};

    my $cmd = shift @$input;

    if ($cmd eq 'do') {
      my $val;

      eval {
        $val = scalar $interface->(@$input);
      };

      my $err = $@;

      if ($err) {
        $err = "$err" if blessed $err;
        $output = ['er', $err,];
      } else {
        $output = ['ok', $val,];
      }

      if ($attempt_graceful_stop) {
        $meta->{sk} = 1;
      }

      push @$output, $meta if keys %$meta;

      my_syswrite($fh, encode_json($output));
    } elsif ($cmd eq 'dn') {
      $output = ['dn',];

      if ($attempt_graceful_stop) {
        $meta->{sk} = 1;
      }

      push @$output, $meta if keys %$meta;

      my_syswrite($fh, encode_json($output));
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
      exit 1; ## probably parent died and we're getting broken pipe
    }

    return if $rv == length($output);

    exit 2; ## partial write: probably the socket is set nonblocking
  }
}

1;
