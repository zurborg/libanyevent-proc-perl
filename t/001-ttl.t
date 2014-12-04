#!perl

use Test::Most;
use AnyEvent::Proc;

plan tests => 1;

SKIP: {
    my $bin = '/bin/cat';
    skip "executable $bin not available", 1 unless -x $bin;
    my $proc = AnyEvent::Proc->new( bin => $bin, ttl => 1 );
    is $proc->wait() => 0, 'wait ok, status is 0';
}

done_testing;
