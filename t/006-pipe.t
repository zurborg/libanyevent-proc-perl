#!perl

use Test::Most;
use AnyEvent;
use AnyEvent::Proc;

sub sync_read {
	my $h = shift;
	my $buf = \( my $str = '' );
	my $cv = AE::cv;
	$h->on_eof(sub {
		$cv->send($$buf);
	});
	$h->on_error(sub {
		diag "error $h: $_[2]";
		$cv->send($$buf);
	});
	$h->on_read(sub {
		$$buf .= $_[0]->rbuf;
		$_[0]->rbuf = '';
	});
	$cv;
}

plan tests => 4;

my ($proc, $R, $W, $cv);

SKIP: {
	my $bin = '/bin/cat';
	skip "executable $bin not available", 4 unless -x $bin;

	($R, $W) = AnyEvent::Proc::_wpipe(sub {});
	$cv = sync_read($R);
	
	$proc = AnyEvent::Proc->new(bin => $bin, ttl => 5);
	$proc->pipe($W);
	$proc->writeln($$);
	$proc->finish;
	is $proc->wait() => 0, 'wait ok, status is 0';
	$W->close;
	like $cv->recv => qr{^$$\s*$}, 'rbuf contains my pid';
	
	
	($R, $W) = AnyEvent::Proc::_rpipe(sub {});
	
	$proc = AnyEvent::Proc->new(bin => $bin, ttl => 5);
	$proc->pipe($W);
	$proc->writeln($$);
	$proc->finish;
	is $proc->wait() => 0, 'wait ok, status is 0';
	$W->destroy;
	like <$R> => qr{^$$\s*$}, 'buf contains my pid';
}

done_testing;
