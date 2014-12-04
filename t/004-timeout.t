#!perl

use Test::Most;
use AnyEvent::Proc;

plan tests => 4;

my $proc;

my $on_ttl = sub { fail('ttl exceeded') };

SKIP: {
    my $bin = '/bin/cat';
    skip "executable $bin not available", 4 unless -x $bin;

    $proc = AnyEvent::Proc->new(
        bin           => $bin,
        timeout       => 1,
        ttl           => 5,
        on_ttl_exceed => $on_ttl
    );
    is $proc->wait() => 0, 'timeout';

    $proc = AnyEvent::Proc->new(
        bin           => $bin,
        wtimeout      => 1,
        ttl           => 5,
        on_ttl_exceed => $on_ttl
    );
    is $proc->wait() => 0, 'wtimeout';

    $proc = AnyEvent::Proc->new(
        bin           => $bin,
        rtimeout      => 1,
        ttl           => 5,
        on_ttl_exceed => $on_ttl
    );
    is $proc->wait() => 0, 'rtimeout';

    $proc = AnyEvent::Proc->new(
        bin           => $bin,
        etimeout      => 1,
        ttl           => 5,
        on_ttl_exceed => $on_ttl
    );
    is $proc->wait() => 0, 'etimeout';
}

done_testing;
