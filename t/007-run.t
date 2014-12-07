#!perl

#BEGIN { $ENV{LC_ALL} = 'C' }

use Test::Most;
use AnyEvent;
use AnyEvent::Proc qw(run run_cb);

BEGIN {
	delete @ENV{qw{ LANG LANGUAGE }};
	$ENV{LC_ALL} = 'C';
}

plan tests => 6;

my ( $out, $err );

SKIP: {
    my $bin = '/bin/echo';
    skip "executable $bin not available", 1 unless -x $bin;
    $out = run( $bin => $$ );
    like $out => qr{^$$\s*$}, 'stdout is my pid';
}

SKIP: {
    my $bin = '/bin/cat';
    skip "executable $bin not available", 2 unless -x $bin;
    ( $out, $err ) = run( $bin => 'THISFILEDOESNOTEXISTSATALL' );
    like $out => qr{^\s*$}, 'stdout is empty';
    like $err => qr{^.*no such file or directory\s*$}i,
      'stderr hat error message';
}

SKIP: {
    my $bin = '/bin/false';
    skip "executable $bin not available", 1 unless -x $bin;
    run($bin);
    is $?>> 8 => 1,
      'exit code is properly saved in $?';
}

SKIP: {
    my $bin = '/bin/echo';
    skip "executable $bin not available", 1 unless -x $bin;
    my $cv = AE::cv;
    run_cb(
        $bin => $$,
        sub {
            is $?>> 8 => 0, 'exit code is properly saved in $?';
            $cv->send(@_);
        }
    );
    my ($out) = $cv->recv;
    like $out => qr{^$$\s*$}, 'run_cb works as expected';
}

done_testing;
