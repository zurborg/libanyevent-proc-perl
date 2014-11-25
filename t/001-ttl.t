#!perl

use Test::Most;
use AnyEvent::Proc;

plan tests => 1;

my $proc = AnyEvent::Proc->new(bin => '/bin/cat', ttl => 1);
is $proc->wait() => 0, 'wait ok, status is 0';

done_testing;
