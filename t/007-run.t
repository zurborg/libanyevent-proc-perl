#!perl

use Test::Most;
use AnyEvent::Proc qw(run);

plan tests => 4;

my ($out, $err);

SKIP: {
	my $bin = '/bin/echo';
	skip "executable $bin not available", 1 unless -x $bin;
	$out = run($bin => $$);
	like $out => qr{^$$\s*$}, 'stdout is my pid';
}

SKIP: {
	my $bin = '/bin/cat';
	skip "executable $bin not available", 2 unless -x $bin;
	($out, $err) = run($bin => 'THISFILEDOESNOTEXISTSATALL');
	like $out => qr{^\s*$}, 'stdout is empty';
	like $err => qr{^.*no such file or directory\s*$}i, 'stderr hat error message';
}

SKIP: {
	my $bin = '/bin/false';
	skip "executable $bin not available", 1 unless -x $bin;
	run($bin);
	is $?>>8 => 1, 'exit code is properly saved in $?'
}

done_testing;
