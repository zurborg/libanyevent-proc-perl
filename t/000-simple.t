#!perl

use Test::Most;
use AnyEvent::Proc;

plan tests => 5;

my $proc = AnyEvent::Proc->new(bin => '/bin/cat', ttl => 5);
ok $proc->alive(), 'proc is alive';
$proc->writeln($$);
ok $proc->alive(), 'proc is still alive (1)';
is $proc->readline() => $$, 'readline returns my pid';
ok $proc->alive(), 'proc is still alive (2)';
$proc->kill();
is $proc->wait() => 0, 'wait ok, status is 0';

done_testing;
