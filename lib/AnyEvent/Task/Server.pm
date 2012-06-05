package AnyEvent::Task::Server;

use common::sense;

use AnyEvent;
use AnyEvent::Util;
use AnyEvent::Socket;

use AnyEvent::Task::Server::Worker;


sub new {
  my ($class, %arg) = @_;
  my $self = {};
  bless $self, $class;


  $self->{all_done_cv} = AE::cv;
  $self->{children} = {};


  $self->{setup} = $arg{setup} || sub {};


  if ($arg{listen}) {
    $self->{listen} = $arg{listen};

    my $host = $self->{listen}->[0];
    my $service = $self->{listen}->[1];

    $self->{server_guard} = tcp_server $host, $service, sub {
      my ($fh) = @_;
      $self->handle_new_connection($fh);
    };
  } else {
    die "unspecified listen path";
  }


  if (exists $arg{interface}) {
    my $interface = $arg{interface};

    if (ref $interface eq 'CODE') {
      $self->{interface} = $interface;
    } elsif (ref $interface eq 'HASH') {
      $self->{interface} = sub {
        my $method = shift;
        $interface->{$method}->(@_);
      };
    } else {
      die "interface must be a sub or a hash";
    }
  } else {
    die "unspecified interface";
  }


  return $self;
}



our @children_sockets;

sub fork_task_server {
  my ($socka, $sockb) = AnyEvent::Util::portable_socketpair;

  my $pid = fork;

  die "couldn't fork: $!" if !defined $pid;

  if (!$pid) {
    close($socka);

    ## !! FIXME: should close all other children_sockets here

    ## If parent closes its side of the socket we should exit
    my $watcher = AE::io $sockb, 0, sub { exit };

    AnyEvent::Task::Server->new(@_)->run;

    die "AnyEvent::Task::Server->run should never return";
  }

  close $sockb;

  return ($socka, $pid) if wantarray;

  push @children_sockets, $socka; # keep reference alive
  return;
}



sub handle_new_connection {
  my ($self, $fh) = @_;

  my ($monitor_fh1, $monitor_fh2) = AnyEvent::Util::portable_socketpair;

  my $rv = fork;

  if ($rv) {
    close($fh);
    close($monitor_fh2);

    $self->{children}->{$rv} = {
      monitor_fh => $monitor_fh1,
    };
  } elsif ($rv == 0) {
    close($monitor_fh1);

    ## !! FIXME: close $self->{children}->{*}->{monitor_fh}

    $self->{setup}->();

    AnyEvent::Task::Server::Worker::handle_worker($self->{interface}, $fh, $monitor_fh2);
    die "handle_worker should never return";
  } else {
    close($fh);
    close($monitor_fh1);
    close($monitor_fh2);
    die "fork failed: $!"; ## FIXME: should just log this instead
  }
}


sub run {
  my ($self) = @_;

  $self->{all_done_cv}->recv;
}


1;
