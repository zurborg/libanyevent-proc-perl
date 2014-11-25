#!perl

use Test::Most;
use AnyEvent::Proc;

plan tests => 2;

my $ok;
{
	local $_ = 0;
	$ok = \$_;
}

my $proc = AnyEvent::Proc->new(bin => '/bin/cat', on_exit => sub { $$ok = 1 }, ttl => 5);
$proc->kill();
is $proc->wait() => 0, 'wait ok, status is 0';
is $$ok => 1, 'on_exit handler called';

done_testing;
