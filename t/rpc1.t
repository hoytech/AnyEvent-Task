use strict;

use Data::Dumper;
use Session::Token;

use RPC::Pipelined::Client;
use RPC::Pipelined::Server;


my $c = RPC::Pipelined::Client->new;

my $pr = $c->run('new');
$c->run('get', $pr);

my $m = $c->pack_msg;


my $s = RPC::Pipelined::Server->new(
  interface => sub {
    my ($cmd, $param) = @_;
    return Session::Token->new if $cmd eq 'new';
    return $param->get if $cmd eq 'get';
  },
);

my $rm = $s->exec($m);
my $r = $c->unpack_response($rm);
print Dumper($r);
