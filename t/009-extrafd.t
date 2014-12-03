#!perl

use Test::Most;
use AnyEvent;
use AnyEvent::Proc;
use IO::Pipe;

plan tests => 7;

my ($proc, $out, $err);

SKIP: {
	my $bin = '/bin/sh';
	skip "executable $bin not available", 6 unless -x $bin;
	
	my $h1 = AnyEvent::Proc::reader();
	my $h1out = '';

	$proc = AnyEvent::Proc->new(bin => $bin, args => [ -c => 'echo hi >&$0', $h1 ], ttl => 5, outstr => \$out, errstr => \$err);
	$h1->pipe(\$h1out);

	$proc->finish;
	is $proc->wait() => 0, 'wait ok, status is 0';
	is $err => '';
	is $out => '';
	like $h1out => qr{^hi\s+$};

	my $h2 = AnyEvent::Proc::writer();
	
	$proc = AnyEvent::Proc->new(bin => $bin, args => [ -c => 'cat <&$0', $h2 ], ttl => 5, outstr => \$out, errstr => \$err);
	$h2->writeln('hi');
	$h2->finish;
	$proc->finish;
	is $proc->wait() => 0, 'wait ok, status is 0';
	is $err => '';
	like $out => qr{^hi\s+$};

}

done_testing;
