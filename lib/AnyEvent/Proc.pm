use strict;
use warnings;
package AnyEvent::Proc;
# ABSTRACT: Run external commands

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Util ();
use Try::Tiny;
use POSIX;

# VERSION

=head1 SYNOPSIS

	my $proc = AnyEvent::Proc->new(bin => 'cat');
	$proc->writeln('hello');
	my $hello = $proc->readline;
	$proc->kill;
	$proc->wait;

=cut

sub _rpipe(&) {
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

sub _wpipe(&) {
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

sub _reaper {
	my $waiters = shift;
	sub {
		# my $message = shift; # currently unused
		foreach (@$waiters) {
			if (ref $_ eq 'CODE') {
				$_->(undef);
			} elsif (ref $_ eq 'AnyEvent::CondVar') {
				$_->send(undef);
			} elsif (ref $_ eq 'Coro::Channel') {
				$_->shutdown;
			} else {
				AE::log note => "cannot reap $_";
			}
		}
	}
}

sub _push_waiter {
	my ($self, $what, $var) = @_;
	push @{$self->{waiters}->{$what}} => $var;
}

sub _run_cmd($$$$$) {
	my ($cmd, $stdin, $stdout, $stderr, $pidref) = @_;
 
	my $cv = AE::cv;
 
	my %redir = (
		0 => $stdin,
		1 => $stdout,
		2 => $stderr,
	);
	
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
 
		# close everything else, except 0, 1, 2
        AnyEvent::Util::close_all_fds_except 0, 1, 2;
 
		my $bin = $cmd->[0];
 
		no warnings;

		exec { $bin } @$cmd;

		exit 126;
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
		AE::log warn => "child exited with status $status" if $status;
		undef $cw;
		$cv->end;
	};
	
 	$cv;
}

=method new(%options)

=over 4

=item * I<bin>

Name (or path) to a binary

=item * I<args> (optional)

ArrayRef with command arguments

=item * I<timeout> (optional)

Timeout after the process automatically gets killed

=item * I<outstr>

When set to a ScalarRef, any output (STDOUT) will be appended to this scalar

=item * I<errstr>

Same as I<outstr>, but for STDERR.

=item * I<on_exit>

Callback handle when process exited

=back

=cut

sub new($%) {
	my ($class, %options) = @_;
	
	$options{args} ||= [];
	
	my $eof_in;
	my $eof_out;
	my $eof_err;
	
	my ($rIN , $wIN , $cvIN ) = _rpipe { $$eof_in->(@_) };
	my ($rOUT, $wOUT, $cvOUT) = _wpipe { $$eof_out->(@_) };
	my ($rERR, $wERR, $cvERR) = _wpipe { $$eof_err->(@_) };
	
	my $pid;

	my $cv = _run_cmd([ delete $options{bin} => @{delete $options{args}} ], $rIN, $wOUT, $wERR, \$pid);
	
	my $self = bless {
		in => $wIN,
		out => $rOUT,
		err => $rERR,
		pid => $pid,
		listeners => {
			exit => $options{on_exit},
			eof_stdin  => delete $options{on_eof_stdin},
			eof_stdout => delete $options{on_eof_stdout},
			eof_stderr => delete $options{on_eof_stderr},
		},
		cv => $cv,
		waiters => {
			in => [],
			out => [],
			err => [],
		},
	} => ref $class || $class;
	
	my $w;
	if ($options{timeout}) {
		$w = AnyEvent->timer(after => delete $options{timeout}, cb => sub {
			return unless $self->alive;
			$self->kill('KILL');
			$self->_emit('on_timeout');
		});
	}
	
	if ($options{errstr}) {
		my $sref = delete $options{errstr};
		$rERR->on_read(sub {
			local $_ = shift;
			$$sref .= $_->rbuf;
			$_->rbuf = '';
		});
	}
	
	if ($options{outstr}) {
		my $sref = delete $options{outstr};
		$rOUT->on_read(sub {
			local $_ = shift;
			$$sref .= $_->rbuf;
			$_->rbuf = '';
		});
	}
	
	$cvIN->cb(_reaper($self->{waiters}->{in}));
	$cvOUT->cb(_reaper($self->{waiters}->{out}));
	$cvERR->cb(_reaper($self->{waiters}->{err}));
	
	$$eof_in  = sub { $self->_emit(eof_stdin  => @_); };
	$$eof_out = sub { $self->_emit(eof_stdout => @_); };
	$$eof_err = sub { $self->_emit(eof_stderr => @_); };
	
	$cv->cb(sub {
		undef $w;
		$self->_emit(exit => shift->recv);
	});
	
	$self;
}

=method in()

Returns a L<AnyEvent::Handle> for STDIN

=cut

sub in  { shift->{in}  }

=method out()

Returns a L<AnyEvent::Handle> for STDOUT

=cut

sub out { shift->{out} }

=method err()

Returns a L<AnyEvent::Handle> for STDERR

=cut

sub err { shift->{err} }

sub _emit($$@) {
	my ($self, $name, @args) = @_;
	if (exists $self->{listeners}->{$name} and defined $self->{listeners}->{$name}) {
		$self->{listeners}->{$name}->($self, @args);
	}
}

=method pid()

Returns the PID of the subprocess

=cut

sub pid($) {
	shift->{pid};
}

=method kill([$signal])

Sends a named signal to the subprocess. C<$signal> defaults to I<INT> if omitted.

=cut

sub kill($;$) {
	my ($self, $signal) = @_;
	$signal = 'INT' unless defined $signal;
	kill $signal => $self->pid;
}

=method alive()

Check whether is subprocess is still alive. Returns I<1> or I<0>

In fact, the method equals to

	$proc->kill(0)

=cut

sub alive($) {
	shift->kill(0) ? 1 : 0;
}

=method wait()

Waits for the subprocess to be finished returns the exit code.

=cut

sub wait($) {
	my ($self) = @_;
	my $status = $self->{cv}->recv;
	waitpid $self->{pid} => 0;
	$status;
}

=method write($scalar)

Queues the given scalar to be written.

=method write($type => @args)

See L<AnyEvent::Handle>::push_write for more information.

=cut

sub write($$;@) {
	my ($self, $type, @args) = @_;
	my $ok = 0;
	try {
		$self->{in}->push_write($type => @args);
		$ok = 1;
	} catch {
		AE::log warn => $_;
	};
	$ok;
}

=method writeln(@lines)

Queues one or more line to be written.

=cut

sub writeln($@) {
	my ($self, @lines) = @_;
	$self->write("$_\n") for @lines;
}

sub _push_read($$@) {
	my ($self, $what, @args) = @_;
	my $ok = 0;
	try {
		$self->{$what}->push_read(@args);
		$ok = 1;
	} catch {
		AE::log warn => "cannot push_read from std$what: $_";
	};
	$ok;
}

sub _unshift_read($$@) {
	my ($self, $what, @args) = @_;
	my $ok = 0;
	try {
		$self->{$what}->unshift_read(@args);
		$ok = 1;
	} catch {
		AE::log warn => "cannot unshift_read from std$what: $_";
	};
	$ok;
}

sub _readline($$$) {
	my ($self, $what, $sub) = @_;
	$self->_push_read($what => line => $sub);
}

sub _readchunk($$$$) {
	my ($self, $what, $bytes, $sub) = @_;
	$self->_push_read($what => chunk => $bytes => $sub);
}

sub _sub_cb($) {
	my ($cb) = @_;
	sub { $cb->($_[1]) }
}

sub _sub_cv($) {
	my ($cv) = @_;
	sub { $cv->send($_[1]) }
}

sub _sub_ch($) {
	my ($ch) = @_;
	sub { $ch->put($_[1]) }
}

sub _readline_cb($$$) {
	my ($self, $what, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_readline($what => _sub_cb($cb));
}

sub _readline_cv($$;$) {
	my ($self, $what, $cv) = @_;
	$cv ||= AE::cv;
	$self->_push_waiter($what => $cv);
	$cv->send unless $self->_readline($what => _sub_cv($cv));
	$cv;
}

sub _readline_ch($$;$) {
	my ($self, $what, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_readline($what => _sub_ch($channel));
	$channel;
}

sub _readlines_ch($$;$) {
	my ($self, $what, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->$what->on_read(sub {
		$self->_readline($what => _sub_ch($channel));
	});
	$channel;
}

sub _readchunk_cb($$$$) {
	my ($self, $what, $bytes, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_readchunk($what, $bytes, _sub_cb($cb));
}

sub _readchunk_cv($$$;$) {
	my ($self, $what, $bytes, $cv) = @_;
	$cv ||= AE::cv;
	$self->_push_waiter($what => $cv);
	$self->_readchunk($what, $bytes, _sub_cv($cv));
	$cv;
}

sub _readchunk_ch($$$;$) {
	my ($self, $what, $bytes, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_readline($what => _sub_ch($channel));
	$channel;
}

sub _readchunks_ch($$$;$) {
	my ($self, $what, $bytes, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->$what->on_read(sub {
		$self->_readline($what => _sub_ch($channel));
	});
	$channel;
}

=method readline_cb($callback)

Reads a single line from STDOUT and calls C<$callback>

=cut

sub readline_cb($$) {
	my ($self, $cb) = @_;
	$self->_readline_cb(out => $cb);
}

=method readline_cv([$condvar])

Reads a single line from STDOUT and send the result to C<$condvar>. A condition variable will be created and returned, if C<$condvar> is omitted.

=cut

sub readline_cv($;$) {
	my ($self, $cv) = @_;
	$self->_readline_cv(out => $cv);
}

=method readline_cv([$channel])

Reads a singe line from STDOUT and put the result to coro channel C<$channel>. A L<Coro::Channel> will be created and returned, if C<$channel> is omitted.

=cut

sub readline_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readline_ch(out => $ch);
}

=method readlines_cv([$channel])

Read lines continiously from STDOUT and put every line to coro channel C<$channel>. A L<Coro::Channel> will be created and returned, if C<$channel> is omitted.

=cut

sub readlines_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readlines_ch(out => $ch);
}

=method readline()

Reads a single line from STDOUT synchronously and return the result.

Same as

	$proc->readline_cv->recv

=cut

sub readline($) {
	shift->readline_cv->recv
}

=method readline_error_cb($callback)

Bevahes equivalent as I<readline_cb>, but for STDERR.

=cut

sub readline_error_cb($$) {
	my ($self, $cb) = @_;
	$self->_readline_cb(err => $cb);
}

=method readline_error_cv([$condvar])

Bevahes equivalent as I<readline_cv>, but for STDERR.

=cut

sub readline_error_cv($;$) {
	my ($self, $cv) = @_;
	$self->_readline_cv(err => $cv);
}

=method readline_error_ch([$channel])

Bevahes equivalent as I<readline_ch>, but for STDERR.

=cut

sub readline_error_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readline_ch(err => $ch);
}

=method readlines_error_ch([$channel])

Bevahes equivalent as I<readlines_ch>, but for STDERR.

=cut

sub readlines_error_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readlines_ch(out => $ch);
}

=method readline_error()

Bevahes equivalent as I<readline>, but for STDERR.

=cut

sub readline_error($) {
	shift->readline_error_cv->recv
}

1;
