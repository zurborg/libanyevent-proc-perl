#!perl

use Test::Most;
use AnyEvent::Proc;

my $proc;

my $on_ttl = sub { fail('ttl exceeded') };

$proc = AnyEvent::Proc->new(bin => '/bin/cat',  timeout => 1, ttl => 5, on_ttl_exceed => $on_ttl);
is $proc->wait() => 0, 'timeout';

$proc = AnyEvent::Proc->new(bin => '/bin/cat', wtimeout => 1, ttl => 5, on_ttl_exceed => $on_ttl);
is $proc->wait() => 0, 'wtimeout';

$proc = AnyEvent::Proc->new(bin => '/bin/cat', rtimeout => 1, ttl => 5, on_ttl_exceed => $on_ttl);
is $proc->wait() => 0, 'rtimeout';

$proc = AnyEvent::Proc->new(bin => '/bin/cat', etimeout => 1, ttl => 5, on_ttl_exceed => $on_ttl);
is $proc->wait() => 0, 'etimeout';

done_testing;
