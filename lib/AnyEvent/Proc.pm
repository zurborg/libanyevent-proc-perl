use strict;
use warnings;
package AnyEvent::Proc;
# ABSTRACT: Run external commands

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Util ();
use Try::Tiny;
use Exporter qw(import);
use POSIX;

# VERSION

=head1 SYNOPSIS

	my $proc = AnyEvent::Proc->new(bin => 'cat');
	$proc->writeln('hello');
	my $hello = $proc->readline;
	$proc->fire;
	$proc->wait;

=head1 DESCRIPTION

AnyEvent::Proc is a L<AnyEvent>-based helper class for running external commands with full control over STDIN, STDOUT and STDERR.

=head1 EXPORTS

Nothing by default. The following functions will be exported on request:

=over 4

=item * L</run>

=item * L</reader>

=item * L</writer>

=back

=cut

our @EXPORT_OK = qw(run reader writer);

sub _rpipe {
	my $on_eof = shift;
	my ($R, $W) = AnyEvent::Util::portable_pipe;
	my $cv = AE::cv;
	(
		$R,
		AnyEvent::Handle->new(
			fh => $W,
			on_error => sub {
				my ($handle, $fatal, $message) = @_;
				AE::log warn => "error writing to handle: $message";
				$cv->send($message);
			},
			on_eof => $on_eof,
		),
		$cv,
	);
}

sub _wpipe {
	my $on_eof = shift;
	my ($R, $W) = AnyEvent::Util::portable_pipe;
	my $cv = AE::cv;
	(
		AnyEvent::Handle->new(
			fh => $R,
			on_error => sub {
				my ($handle, $fatal, $message) = @_;
				AE::log warn => "error reading from handle: $message";
				$cv->send($message);
			},
			on_eof => $on_eof,
		),
		$W,
		$cv,
	);
}

sub _on_read_helper {
	my ($aeh, $sub) = @_;
	$aeh->on_read(sub {
		my $x = $_[0]->rbuf;
		$_[0]->rbuf = '';
		$sub->($x);
	});
}

sub _reaper {
	my ($self, $waiters) = @_;
	my $sub = sub {
		# my $message = shift; # currently unused
		foreach my $waiter (@$waiters) {
			AE::log debug => "reap $waiter";
			if (ref $waiter eq 'CODE') {
				$waiter->(undef);
			} elsif (ref $waiter eq 'AnyEvent::CondVar') {
				$waiter->send(undef);
			} elsif (ref $waiter eq 'Coro::Channel') {
				$waiter->shutdown;
			} else {
				AE::log note => "cannot reap $waiter";
			}
		}
	};
	push @{$self->{reapers}} => $sub;
	$sub;
}

sub _push_waiter {
	my ($self, $what, $var) = @_;
	push @{$self->{waiters}->{$what}} => $var;
}

sub _run_cmd {
	my ($cmd, $redir, $pidref) = @_;
 
	my $cv = AE::cv;
	
	my %redir = %$redir;

	my $pid = fork;
	AE::log error => "cannot fork: $!" unless defined $pid;
 
	unless ($pid) {
		# move any existing fd's out of the way
		# this also ensures that dup2 is never called with fd1==fd2
		# so the cloexec flag is always cleared
	    my (@oldfh, @close);
		for my $fh (values %redir) {
			push @oldfh, $fh; # make sure we keep it open
			$fh = fileno $fh; # we only want the fd
 
			# dup if we are in the way
			# if we "leak" fds here, they will be dup2'ed over later
			defined ($fh = POSIX::dup ($fh)) or POSIX::_exit (124)
				while exists $redir{$fh};
		}
 
		# execute redirects
		while (my ($k, $v) = each %redir) {
			defined POSIX::dup2 ($v, $k)
				or POSIX::_exit (123);
		}
 
		AnyEvent::Util::close_all_fds_except(keys %redir);
 
		my $bin = $cmd->[0];

		no warnings; ## no critic

		exec { $bin } @$cmd;

		POSIX::_exit (126);
	}
 
	$$pidref = $pid;
 
	%redir = (); # close child side of the fds
 
	my $status;
	$cv->begin (sub {
		shift->send ($status)
	});
	
	my $cw;
	$cw = AE::child $pid => sub {
		$status = $_[1] >> 8;
		my $signal = $_[1] & 127;
		my $coredump = $_[1] & 128;
		AE::log info => "child exited with status $status" if $status;
		AE::log debug => "child exited with signal $signal" if $signal;
		AE::log note => "child exited with coredump" if $coredump;
		undef $cw;
		$cv->end;
	};
	
 	$cv;
}

=method new(%options)

=over 4

=item * I<bin> (mandatory)

Name (or path) to a binary

=item * I<args>

ArrayRef with command arguments

=item * I<ttl>

Time-to-life timeout after the process automatically gets killed

See also I<on_ttl_exceed> callback handler.

=item * I<timeout>

Inactive timeout value (fractional seconds) for all handlers.

See also I<on_timeout> callback handler. If omitted, after exceeding timeout all handlers will be closed and the subprocess can finish.

=item * I<wtimeout>

Like I<timeout> but sets only the write timeout value for STDIN.

Corresponding callback handler: I<on_wtimeout>

=item * I<rtimeout>

Like I<timeout> but sets only the read timeout value for STDOUT.

Corresponding callback handler: I<on_rtimeout>

=item * I<etimeout>

Like I<timeout> but sets only the read timeout value for STDERR.

Corresponding callback handler: I<on_etimeout>

=item * I<outstr>

When set to a ScalarRef, any output (STDOUT) will be appended to this scalar

=item * I<errstr>

Same as I<outstr>, but for STDERR.

=item * I<on_exit>

Callback handler called when process exits

=item * I<on_ttl_exceed>

Callback handler called when I<ttl> exceeds

=item * I<on_timeout>

Callback handler called when any inactivity I<timeout> value exceeds

=item * I<on_wtimeout>

Callback handler called when STDIN write inactivity I<wtimeout> value exceeds

=item * I<on_rtimeout>

Callback handler called when STDOUT read inactivity I<rtimeout> value exceeds

=item * I<on_etimeout>

Callback handler called when STDERR read inactivity I<etimeout> value exceeds

=back

=cut

sub new {
	my ($class, %options) = @_;
	
	$options{args} ||= [];
	
	my $eof_in;
	my $eof_out;
	my $eof_err;
	
	my ($rIN , $wIN , $cvIN ) = _rpipe sub { $$eof_in->(@_) };
	my ($rOUT, $wOUT, $cvOUT) = _wpipe sub { $$eof_out->(@_) };
	my ($rERR, $wERR, $cvERR) = _wpipe sub { $$eof_err->(@_) };
	
	my @xhs = @{ delete($options{extras}) || [] };

	my @args = map { "$_" } @{delete $options{args}};

	my $pid;

	my %redir = (
		0 => $rIN,
		1 => $wOUT,
		2 => $wERR,
		map {( "$_" => $_->B )} @xhs
	);

	my $cv = _run_cmd([ delete $options{bin} => @args ], \%redir, \$pid);
	
	my $self = bless {
		handles => {
			in => $wIN,
			out => $rOUT,
			err => $rERR,
			map {( "$_" => $_->A )} @xhs,
		},
		pid => $pid,
		listeners => {
			exit => delete $options{on_exit},
			ttl_exceed => delete $options{on_ttl_exceed},
			#eof_stdin  => delete $options{on_eof_stdin},
			#eof_stdout => delete $options{on_eof_stdout},
			#eof_stderr => delete $options{on_eof_stderr},
		},
		eol => "\n",
		cv => $cv,
		waiters => {
			in => [],
			out => [],
			err => [],
		},
		reapers => [],
	} => ref $class || $class;

	map { $_->{proc} = $self } @xhs;

	{
		my $eol = quotemeta $self->_eol;
		$self->{reol} = delete $options{reol} || qr{$eol};
	}
	
	my $w;
	if ($options{ttl}) {
		$w = AnyEvent->timer(after => delete $options{ttl}, cb => sub {
			return unless $self->alive;
			$self->kill;
			$self->_emit('ttl_exceed');
		});
	}
	
	my $kill = sub { $self->end };
	
	if ($options{timeout}) {
		$wIN->timeout($options{timeout});
		$rOUT->timeout($options{timeout});
		$rERR->timeout($options{timeout});
		delete $options{timeout};
		
		$self->_on(timeout => (delete ($options{on_timeout}) || $kill));
		my $cb = sub { $self->_emit('timeout') };
		$wIN->on_timeout($cb);
		$rOUT->on_timeout($cb);
		$rERR->on_timeout($cb);
	}
	
	if ($options{wtimeout}) {
		$wIN->wtimeout(delete $options{wtimeout});
		
		$self->_on(wtimeout => (delete($options{on_wtimeout}) || $kill));
		my $cb = sub { $self->_emit('wtimeout') };
		$wIN->on_wtimeout($cb);
	}
	
	if ($options{rtimeout}) {
		$rOUT->rtimeout(delete $options{rtimeout});
		
		$self->_on(rtimeout => (delete($options{on_rtimeout}) || $kill));
		my $cb = sub { $self->_emit('rtimeout') };
		$rOUT->on_rtimeout($cb);
	}

	if ($options{etimeout}) {
		$rERR->rtimeout(delete $options{etimeout});
		
		$self->_on(etimeout => (delete($options{on_etimeout}) || $kill));
		my $cb = sub { $self->_emit('etimeout') };
		$rERR->on_rtimeout($cb);
	}
	
	if ($options{errstr}) {
		my $sref = delete $options{errstr};
		$$sref = '';
		$self->pipe(err => $sref);
	}
	
	if ($options{outstr}) {
		my $sref = delete $options{outstr};
		$$sref = '';
		$self->pipe(out => $sref);
	}
	
	$cvIN->cb($self->_reaper($self->{waiters}->{in}));
	$cvOUT->cb($self->_reaper($self->{waiters}->{out}));
	$cvERR->cb($self->_reaper($self->{waiters}->{err}));
	map { $_->{cv}->cb($self->_reaper($self->{waiters}->{"$_"})) } @xhs;
	
	$$eof_in  = sub { $self->_emit(eof_stdin  => @_); };
	$$eof_out = sub { $self->_emit(eof_stdout => @_); };
	$$eof_err = sub { $self->_emit(eof_stderr => @_); };
	
	$cv->cb(sub {
		undef $w;
		$self->_emit(exit => shift->recv);
	});
	
	if (keys %options) {
		AE::log note => "unknown left-over option(s): ".join ', ' =>  keys %options;
	}
	
	$self;
}

=func reader()

Creates a new file descriptor for pulling data from process.

	use AnyEvent::Proc qw(reader);
	my $reader = reader();
	my $proc = AnyEvent::Proc->new(
		bin => '/bin/sh',
		args => [ -c => "echo hi >&$reader" ] # overloads to fileno
		extras => [ $reader ], # unordered list of all extra descriptors
	);
	my $out;
	$reader->pipe(\$out);
	$proc->wait;
	# $out contains now 'hi'

This calls C</bin/sh -c "echo hi >&3">, so that any output will be dupped into fd #3.

C<$reader> provides following methods:

=over 4

=item * L</on_timeout>

=item * L</stop_timeout>

=item * L</pipe>

=item * L</readline_cb>

=item * L</readline_cv>

=item * L</readline_ch>

=item * L</readlines_cb>

=item * L</readlines_ch>

=item * L</readline>

=back

=cut

sub reader {
	my $eof = sub {};
	my ($r, $w, $cv) = _wpipe sub { $$eof->(@_) };
	bless { r => $r, w => $w, eof => $eof, cv => $cv } => __PACKAGE__.'::R';
}

=func writer()

Creates a new file descriptor for pushing data to process.

	use AnyEvent::Proc qw(writer);
	my $writer = writer();
	my $out;
	my $proc = AnyEvent::Proc->new(
		bin => '/bin/sh',
		args => [ -c => "cat <&$writer" ] # overloads to fileno
		extras => [ $writer ], # unordered list of all extra descriptors
		outstr => \$out,
	);
	my $out;
	$writer->writeln('hi');
	$writer->finish;
	$proc->wait;
	# $out contains now 'hi'

This calls C</bin/sh -c "cat <&3">, so that any input will be dupped from fd #3.

C<$writer> provides following methods:

=over 4

=item * L</finish>

=item * L</on_timeout>

=item * L</stop_timeout>

=item * L</write>

=item * L</writeln>

=back

Unfortunally L</pull> is unimplemented.

=cut

sub writer {
	my $eof = sub {};
	my ($r, $w, $cv) = _rpipe sub { $$eof->(@_) };
	bless { r => $r, w => $w, eof => $eof, cv => $cv } => __PACKAGE__.'::W';
}

=func run($bin[, @args])

Bevahes similar to L<perlfunc/system>. In scalar context, it returns STDOUT of the subprocess. STDERR will be passed-through by L<perlfunc/warn>.

	$out = AnyEvent::Proc::run(...)

In list context, STDOUT and STDERR will be separately returned.

	($out, $err) = AnyEvent::Proc::run(...)

The exit-code is stored in C<$?>. Please keep in mind that for portability reasons C<$?> is shifted by 8 bits.

	$exitcode = $? >> 8

=cut

sub run {
	my ($bin, @args) = @_;
	my ($out, $err) = ('', '');
	my $proc = __PACKAGE__->new(bin => $bin, args => \@args, outstr => \$out, errstr => \$err);
	$proc->finish;
	$? = $proc->wait << 8;
	if (wantarray) {
		return ($out, $err);
	} else {
		warn $err if $err;
		return $out;
	}
}

sub _on {
	my ($self, $name, $handler) = @_;
	$self->{listeners}->{$name} = $handler;
}

=method in()

Returns a L<AnyEvent::Handle> for STDIN

Useful for piping data into us:

	$socket->print($proc->in->fh)

=cut

sub in  { shift->_geth('in')  }

=method out()

Returns a L<AnyEvent::Handle> for STDOUT

=cut

sub out { shift->_geth('out') }

=method err()

Returns a L<AnyEvent::Handle> for STDERR

=cut

sub err { shift->_geth('err') }

sub _geth {
	shift->{handles}->{pop()}
}

sub _eol { shift->{eol} }
sub _reol { shift->{reol} }

sub _emit {
	my ($self, $name, @args) = @_;
	AE::log debug => "trapped $name";
	if (exists $self->{listeners}->{$name} and defined $self->{listeners}->{$name}) {
		$self->{listeners}->{$name}->($self, @args);
	}
}

=method pid()

Returns the PID of the subprocess

=cut

sub pid {
	shift->{pid};
}

=method fire([$signal])

Sends a named signal to the subprocess. C<$signal> defaults to I<TERM> if omitted.

=cut

sub fire {
	my ($self, $signal) = @_;
	$signal = 'TERM' unless defined $signal;
	kill uc $signal => $self->pid;
	$self;
}

=method kill()

Kills the subprocess the most brutal way. Equals to

	$proc->fire('kill')

=cut

sub kill {
	my ($self) = @_;
	$self->fire('kill');
}

=method fire_and_kill([$signal, ]$time)

Fires specified signal C<$signal> (or I<TERM> if omitted) and after C<$time> seconds kills the subprocess.

This is a synchronous call. After this call, the subprocess can be considered to be dead.

Returns the exit code of the subprocess.

=cut

sub fire_and_kill {
	my $self = shift;
	my $time = pop;
	my $signal = uc (pop || 'TERM');
	my $w = AnyEvent->timer(after => $time, cb => sub {
		return unless $self->alive;
		$self->kill;
	});
	$self->fire($signal);
	my $exit = $self->wait;
	undef $w;
	$exit;
}

=method alive()

Check whether is subprocess is still alive. Returns I<1> or I<0>

In fact, the method equals to

	$proc->fire(0)

=cut

sub alive {
	shift->fire(0) ? 1 : 0;
}

=method wait()

Waits for the subprocess to be finished returns the exit code.

=cut

sub wait {
	my ($self) = @_;
	my $status = $self->{cv}->recv;
	waitpid $self->{pid} => 0;
	$self->end;
	$status;
}

=method finish()

Closes STDIN of subprocess

=cut

sub finish {
	my ($self) = @_;
	$self->in->destroy;
	$self;
}

=method end()

Closes all handles of subprocess

=cut

sub end {
	my ($self) = @_;
	$self->in->destroy;
	$self->out->destroy;
	$self->err->destroy;
	$self;
}

=method stop_timeout()

Stopps read/write timeout for STDIN, STDOUT and STDERR.

See I<timeout> and I<on_timeout> options in I<new()>.

=cut

sub stop_timeout {
	my ($self) = @_;
	$self->in->timeout(0);
	$self->out->timeout(0);
	$self->err->timeout(0);
}

=method stop_wtimeout()

Stopps write timeout for STDIN.

See I<wtimeout> and I<on_wtimeout> options in I<new()>.

=cut

sub stop_wtimeout {
	my ($self) = @_;
	$self->in->wtimeout(0);
}

=method stop_rtimeout()

Stopps read timeout for STDIN.

See I<rtimeout> and I<on_rtimeout> options in I<new()>.

=cut

sub stop_rtimeout {
	my ($self) = @_;
	$self->out->rtimeout(0);
}

=method stop_etimeout()

Stopps read timeout for STDIN.

See I<etimeout> and I<on_etimeout> options in I<new()>.

=cut

sub stop_etimeout {
	my ($self) = @_;
	$self->err->rtimeout(0);
}

=method write($scalar)

Queues the given scalar to be written.

=method write($type => @args)

See L<AnyEvent::Handle>::push_write for more information.

=cut

sub write {
	my ($self, $type, @args) = @_;
	my $ok = 0;
	try {
		$self->_geth('in')->push_write($type => @args);
		$ok = 1;
	} catch {
		AE::log warn => $_;
	};
	$ok;
}

=method writeln(@lines)

Queues one or more line to be written.

=cut

sub writeln {
	my ($self, @lines) = @_;
	$self->write($_.$self->_eol) for @lines;
	$self;
}

=method pipe([$fd, ]$peer)

Pipes any output of STDOUT to another handle. C<$peer> maybe another L<AnyEvent::Proc> instance, an L<AnyEvent::Handle>, a L<Coro::Channel>, an object that implements the I<print> method (like L<IO::Handle>, including any subclass), a ScalarRef or a GlobRef or a CodeRef.

C<$fd> defaults to I<stdout>.

	$proc->pipe(stderr => $socket);

=cut

sub pipe {
	my $self = shift;
	my $peer = pop;
	my $what = (pop || 'out');
	if (ref $what) {
		$what = "$what";
	} else {
		$what = lc $what;
		$what =~ s{^std}{};
	}
	use Scalar::Util qw(blessed);
	my $sub;
	if (blessed $peer) {
		if ($peer->isa(__PACKAGE__)) {
			$sub = sub {
				$peer->write(shift)
			}
		} elsif ($peer->isa('AnyEvent::Handle')) {
			$sub = sub {
				$peer->push_write(shift)
			}
		} elsif ($peer->isa('Coro::Channel')) {
			$sub = sub {
				$peer->put(shift)
			}
		} elsif ($peer->can('print')) {
			$sub = sub {
				$peer->print(shift)
			}
		}
	} elsif (ref $peer eq 'SCALAR') {
		$sub = sub {
			$$peer .= shift;
		}
	} elsif (ref $peer eq 'GLOB') {
		$sub = sub {
			print $peer shift();
		}
	} elsif (ref $peer eq 'CODE') {
		$sub = $peer
	}
	if ($sub) {
		_on_read_helper($self->_geth($what), $sub)
	} else {
		AE::log fatal => "cannot handle $peer for $what";
	}
}

=method pull($peer)

Pulls any data from another handle to STDIN. C<$peer> maybe another L<AnyEvent::Proc> instance, an L<AnyEvent::Handle>, an L<IO::Handle> (including any subclass), a L<Coro::Channel> or a GlobRef.

	$proc->pull($socket);

=cut

sub pull {
	my ($self, $peer) = @_;
	use Scalar::Util qw(blessed);
	my $sub;
	if (blessed $peer) {
		if ($peer->isa(__PACKAGE__)) {
			return $peer->pipe($self);
		} elsif ($peer->isa('AnyEvent::Handle')) {
			$peer->on_eof(sub {
				AE::log debug => "$peer->on_eof";
				$self->finish;
				shift->destroy;
			});
			$peer->on_error(sub {
				AE::log error => "$peer: ".$_[2];
				$self->finish;
				shift->destroy;
			});
			return _on_read_helper($peer, sub {
				AE::log debug => "$peer->on_read";
				$self->write(shift());
			});
		} elsif ($peer->isa('IO::Handle')) {
			return $self->pull(AnyEvent::Handle->new(fh => $peer))
		} elsif ($peer->isa('Coro::Channel')) {
			require Coro;
			return Coro::async {
				while (my $x = $peer->get) {
					$self->write($x) or last;
					Coro::cede();
				}
			};
		}
	} elsif (ref $peer eq 'GLOB') {
		return $self->pull(AnyEvent::Handle->new(fh => $peer))
	}
	AE::log fatal => "cannot handle $peer for stdin";
}

sub _push_read {
	my ($self, $what, @args) = @_;
	my $ok = 0;
	try {
		$self->_geth($what)->push_read(@args);
		$ok = 1;
	} catch {
		AE::log warn => "cannot push_read from std$what: $_";
	};
	$ok;
}

sub _unshift_read {
	my ($self, $what, @args) = @_;
	my $ok = 0;
	try {
		$self->_geth($what)->unshift_read(@args);
		$ok = 1;
	} catch {
		AE::log warn => "cannot unshift_read from std$what: $_";
	};
	$ok;
}

sub _readline {
	my ($self, $what, $sub) = @_;
	$self->_push_read($what => line => $self->_reol, $sub);
}

sub _readchunk {
	my ($self, $what, $bytes, $sub) = @_;
	$self->_push_read($what => chunk => $bytes => $sub);
}

sub _sub_cb {
	my ($cb) = @_;
	sub { $cb->($_[1]) }
}

sub _sub_cv {
	my ($cv) = @_;
	sub { $cv->send($_[1]) }
}

sub _sub_ch {
	my ($ch) = @_;
	sub { $ch->put($_[1]) }
}

sub _readline_cb {
	my ($self, $what, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_readline($what => _sub_cb($cb));
}

sub _readline_cv {
	my ($self, $what, $cv) = @_;
	$cv ||= AE::cv;
	$self->_push_waiter($what => $cv);
	$cv->send unless $self->_readline($what => _sub_cv($cv));
	$cv;
}

sub _readline_ch {
	my ($self, $what, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_readline($what => _sub_ch($channel));
	$channel;
}

sub _readlines_cb {
	my ($self, $what, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_geth($what)->on_read(sub {
		$self->_readline($what => _sub_cb($cb));
	});
}

sub _readlines_ch {
	my ($self, $what, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_geth($what)->on_read(sub {
		$self->_readline($what => _sub_ch($channel));
	});
	$channel;
}

sub _readchunk_cb {
	my ($self, $what, $bytes, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_readchunk($what, $bytes, _sub_cb($cb));
}

sub _readchunk_cv {
	my ($self, $what, $bytes, $cv) = @_;
	$cv ||= AE::cv;
	$self->_push_waiter($what => $cv);
	$self->_readchunk($what, $bytes, _sub_cv($cv));
	$cv;
}

sub _readchunk_ch {
	my ($self, $what, $bytes, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_readline($what => _sub_ch($channel));
	$channel;
}

sub _readchunks_ch {
	my ($self, $what, $bytes, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_geth($what)->on_read(sub {
		$self->_readline($what => _sub_ch($channel));
	});
	$channel;
}

=method readline_cb($callback)

Reads a single line from STDOUT and calls C<$callback>

=cut

sub readline_cb {
	my ($self, $cb) = @_;
	$self->_readline_cb(out => $cb);
}

=method readline_cv([$condvar])

Reads a single line from STDOUT and send the result to C<$condvar>. A condition variable will be created and returned, if C<$condvar> is omitted.

=cut

sub readline_cv {
	my ($self, $cv) = @_;
	$self->_readline_cv(out => $cv);
}

=method readline_ch([$channel])

Reads a singe line from STDOUT and put the result to coro channel C<$channel>. A L<Coro::Channel> will be created and returned, if C<$channel> is omitted.

=cut

sub readline_ch {
	my ($self, $ch) = @_;
	$self->_readline_ch(out => $ch);
}

=method readlines_cb($callback)

Read lines continiously from STDOUT and calls on every line the handler C<$callback>.

=cut

sub readlines_cb {
	my ($self, $cb) = @_;
	$self->_readlines_cb(out => $cb);
}

=method readlines_ch([$channel])

Read lines continiously from STDOUT and put every line to coro channel C<$channel>. A L<Coro::Channel> will be created and returned, if C<$channel> is omitted.

=cut

sub readlines_ch {
	my ($self, $ch) = @_;
	$self->_readlines_ch(out => $ch);
}

=method readline()

Reads a single line from STDOUT synchronously and return the result.

Same as

	$proc->readline_cv->recv

=cut

sub readline {
	shift->readline_cv->recv
}

=method readline_error_cb($callback)

Bevahes equivalent as I<readline_cb>, but for STDERR.

=cut

sub readline_error_cb {
	my ($self, $cb) = @_;
	$self->_readline_cb(err => $cb);
}

=method readline_error_cv([$condvar])

Bevahes equivalent as I<readline_cv>, but for STDERR.

=cut

sub readline_error_cv {
	my ($self, $cv) = @_;
	$self->_readline_cv(err => $cv);
}

=method readline_error_ch([$channel])

Bevahes equivalent as I<readline_ch>, but for STDERR.

=cut

sub readline_error_ch {
	my ($self, $ch) = @_;
	$self->_readline_ch(err => $ch);
}

=method readlines_error_cb($callback)

Bevahes equivalent as I<readlines_cb>, but for STDERR.

=cut

sub readlines_error_cb {
	my ($self, $cb) = @_;
	$self->_readlines_cb(out => $cb);
}

=method readlines_error_ch([$channel])

Bevahes equivalent as I<readlines_ch>, but for STDERR.

=cut

sub readlines_error_ch {
	my ($self, $ch) = @_;
	$self->_readlines_ch(out => $ch);
}

=method readline_error()

Bevahes equivalent as I<readline>, but for STDERR.

=cut

sub readline_error {
	shift->readline_error_cv->recv
}

# AnyEvent::Impl::Perl has some issues with POSIX::dup.
# This statement solves the problem.
AnyEvent::post_detect {
	AE::child $$ => sub {};
};

1;

package
	AnyEvent::Proc::R;

use overload
	'""' => sub { fileno shift->A->fh };

sub A { shift->{r} }
sub B { shift->{w} }

sub on_timeout {
	shift->A->on_wtimeout(pop);
}

sub stop_timeout {
	shift->A->stop_wtimeout;
}

sub pipe {
	my ($self, $peer) = @_;
	$self->{proc}->pipe($self => $peer);
}

sub readline_cb {
	my ($self, $cb) = @_;
	$self->{proc}->_readline_cb($self => $cb);
}

sub readline_cv {
	my ($self, $cv) = @_;
	$self->{proc}->_readline_cv($self => $cv);
}

sub readline_ch {
	my ($self, $ch) = @_;
	$self->{proc}->_readline_ch($self => $ch);
}

sub readlines_cb {
	my ($self, $cb) = @_;
	$self->{proc}->_readlines_cb($self => $cb);
}

sub readlines_ch {
	my ($self, $ch) = @_;
	$self->{proc}->_readlines_cb($self => $ch);
}

sub readline {
	shift->readline_cv->recv
}


1;

package
	AnyEvent::Proc::W;

use overload
	'""' => sub { fileno shift->A->fh };

use Try::Tiny;

sub A { shift->{w} }
sub B { shift->{r} }

sub finish {
	shift->A->destroy;
}

sub on_timeout {
	shift->A->on_rtimeout(pop);
}

sub stop_timeout {
	shift->A->stop_rtimeout;
}

sub write {
	my ($self, $type, @args) = @_;
	my $ok = 0;
	try {
		$self->A->push_write($type => @args);
		$ok = 1;
	} catch {
		AE::log warn => $_;
	};
	$ok;
}

sub writeln {
	my ($self, @lines) = @_;
	my $eol = $self->{proc}->_eol;
	$self->write($_.$eol) for @lines;
	$self;
}

sub pull { die 'UNIMPLEMENTED' }

1;
