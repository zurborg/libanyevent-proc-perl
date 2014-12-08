#!perl

use Test::Most;
use AnyEvent::Proc;
use Env::Path;

BEGIN {
    delete @ENV{qw{ LANG LANGUAGE }};
    $ENV{LC_ALL} = 'C';
}

plan tests => 1;

SKIP: {
    my ($bin) = Env::Path->PATH->Whence('cat');
    skip "test, reason: executable 'cat' not available", 1 unless $bin;
    my $proc = AnyEvent::Proc->new( bin => $bin, ttl => 1 );
    is $proc->wait() => 0, 'wait ok, status is 0';
}

done_testing;
