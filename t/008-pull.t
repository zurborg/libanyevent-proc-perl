#!perl

use Test::Most;
use AnyEvent;
use AnyEvent::Proc;
use IO::Pipe;

plan tests => 12;

my ( $proc, $R, $W, $out );

SKIP: {
    my $bin = '/bin/cat';
    skip "executable $bin not available", 9 unless -x $bin;

    ( $R, $W ) = AnyEvent::Proc::_wpipe( sub { } );

    $proc = AnyEvent::Proc->new( bin => $bin, ttl => 5, outstr => \$out );
    ok $proc->pull($R);
    print $W "$$\n";
    close $W;
    is $proc->wait() => 0,           'wait ok, status is 0';
    like $out        => qr{^$$\s*$}, 'rbuf contains my pid';

    ( $R, $W ) = AnyEvent::Proc::_rpipe( sub { } );

    $proc = AnyEvent::Proc->new( bin => $bin, ttl => 5, outstr => \$out );
    ok $proc->pull($R);
    $W->push_write("$$\n");
    $W->destroy;
    is $proc->wait() => 0,           'wait ok, status is 0';
    like $out        => qr{^$$\s*$}, 'buf contains my pid';

    ( $R, $W ) = @{ *{ IO::Pipe->new } };

    $proc = AnyEvent::Proc->new( bin => $bin, ttl => 5, outstr => \$out );
    ok $proc->pull($R);
    print $W "$$\n";
    close $W;
    is $proc->wait() => 0,           'wait ok, status is 0';
    like $out        => qr{^$$\s*$}, 'buf contains my pid';

    $proc = AnyEvent::Proc->new( bin => $bin, ttl => 5, outstr => \$out );
    my $in = 'pre';
    ok $proc->pull( \$in );
    $in .= 'post';
    $in = 'overwrite';
    $proc->finish;
    is $proc->wait() => 0, 'wait ok, status is 0';
    like $out => qr{^prepostoverwrite\s*$}, 'buf contains input string';
}

done_testing;
