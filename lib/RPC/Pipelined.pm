package RPC::Pipelined;

use strict;





1;

__END__


CLIENT:

my $rpc = RPC::Pipelined->new;

my $promise = $rpc->run('hash_password', 'password1');

$rpc->run('verify_hash', $promise, 'password1');

my $msg = $rpc->pack_msg;

...

my $val = $rpc->unpack_response($response);



SERVER:

my $response = RPC::Pipelined::exec({ msg => $msg, run_sub => sub {} });
