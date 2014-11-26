#!perl

use Test::Most;
use AnyEvent::Proc qw(run);

#plan tests => 6;

my ($out, $err);

$out = run(echo => $$);
like $out => qr{^$$\s*$}, 'stdout is my pid';

($out, $err) = run(cat => 'THISFILEDOESNOTEXISTSATALL');
like $out => qr{^\s*$}, 'stdout is empty';
like $err => qr{^.*no such file or directory\s*$}i, 'stderr hat error message';

done_testing;
