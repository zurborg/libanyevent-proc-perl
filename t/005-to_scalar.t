#!perl

use Test::Most;
use AnyEvent::Proc;

plan tests => 6;

my ($proc, $out, $err);

$out = '';
$err = '';

$proc = AnyEvent::Proc->new(bin => '/bin/cat', ttl => 5, outstr => \$out, errstr => \$err);
$proc->writeln($$);
$proc->finish;
is $proc->wait() => 0, 'wait ok, status is 0';
like $out => qr{^$$\s*$}, 'stdout is my pid';
like $err => qr{^\s*$}, 'stderr is empty';

$out = '';
$err = '';

$proc = AnyEvent::Proc->new(bin => '/bin/cat', args => [qw[ THISFILEDOESNOTEXISTSATALL ]], ttl => 5, outstr => \$out, errstr => \$err);
$proc->finish;
isnt $proc->wait() => 0, 'wait ok, status isnt 0';
like $out => qr{^\s*$}, 'stdout is empty';
like $err => qr{^.*no such file or directory\s*$}i, 'stderr hat error message';

done_testing;