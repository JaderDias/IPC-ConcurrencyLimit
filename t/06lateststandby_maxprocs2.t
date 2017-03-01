use strict;
use warnings;
use File::Temp;
use File::Path qw(mkpath);
use File::Spec;
use lib '/usr/local/git_tree/IPC-ConcurrencyLimit/lib';
use IPC::ConcurrencyLimit::WithLatestStandby;
use POSIX ":sys_wait_h";
use Test::More;
use Time::HiRes qw(time sleep);
BEGIN {
  if ($^O !~ /linux/i && $^O !~ /win32/i && $^O !~ /darwin/i) {
    Test::More->import(
      skip_all => <<'SKIP_MSG',
Will test the fork-using tests only on linux, win32, darwin since I probably
don't understand other OS well enough to fiddle this test to work
SKIP_MSG
    );
    exit(0);
  }
}

use Test::More tests => 11;

# TMPDIR will hopefully put it in the logical equivalent of
# a /tmp. That is important because no sane admin will mount /tmp
# via NFS and we don't want to fail tests just because we're being
# built/tested on an NFS share.
my $tmpdir = File::Temp::tempdir( CLEANUP => 1, TMPDIR => 1 );
my $standby = File::Spec->catdir($tmpdir, 'latest-standby');
mkpath($standby);

my $debug = 0;
my $out_file="$tmpdir/out.txt";
sub _print {
    open my $out_fh, ">>", $out_file
        or die "failed to write outfile '$out_file':$!";
    my $msg=join "", @_;
    $msg=~s/\n?\z/\n/;
    print $out_fh $msg;
    close $out_fh;
    diag $msg
        if $debug;
};
my $max_procs = 2;
my %shared_opt = (
  max_procs => $max_procs,
  path => $tmpdir,
  poll_time => 0.1,
  debug_sub => sub { _print( "pid: $$: ", @_) },
  debug => 1,
);

SCOPE: {
    my $limit = IPC::ConcurrencyLimit::WithLatestStandby->new(%shared_opt);
    isa_ok($limit, 'IPC::ConcurrencyLimit::WithLatestStandby');

    my $id = $limit->get_lock;
    ok($id, 'Got lock');

    my $max_id= 0;
    my $child_process= sub {
        my $sleep_after_secs= shift || 0.5;
        my $sleep_lock_secs= shift || 0;
        my $id= ++$max_id;
        my $pid= fork() // die "Failed to fork!";
        if (!$pid) {
            # child process
            $limit = IPC::ConcurrencyLimit::WithLatestStandby->new(%shared_opt);
            if ($limit->get_lock) {
                _print("pid: success! got lock $id. (sleeping for $sleep_lock_secs)");
                sleep($sleep_lock_secs) if $sleep_lock_secs;
            } else {
                _print("pid: no lock $id");
            }
            exit(0);
        } else {
            _print("Started $id as $pid (sleeping for $sleep_after_secs)\n");
            sleep($sleep_after_secs) if $sleep_after_secs;
            return $pid;
        }
    };

    my @workers= map $child_process->(0.5, $max_procs), 1..$max_procs;
    is_deeply([ map waitpid($_,WNOHANG), @workers ], [ (0) x $max_procs ],"first worker(s) running");

    for (1..3) {
        my @new_workers= map $child_process->(0.5,2), @workers;
        is_deeply([ map waitpid($_,WNOHANG), @new_workers ], [ (0) x $max_procs ], "new worker(s) running");
        is_deeply([ map waitpid($_,WNOHANG), @workers     ], \@workers           , "old worker(s) stopped")
            or die "Stopping...\n";
        @workers = @new_workers;
    }

    $limit->release_lock();
    diag "sleeping after releasing master lock" if $debug;
    sleep(3); 
    is_deeply([ map waitpid($_,WNOHANG), @workers ], \@workers, "last worker exited after master release_lock");

    my @pids;
    diag "starting 1..30 loop" if $debug;

    for (1..30) {
        my $pid= $child_process->(0.5,2)
            or next;
        push @pids, $pid;
        @pids= grep { 
            my $wait_res= waitpid($workers[0],WNOHANG);
            if (!$wait_res) {
                _print "pid: $_: exited";
            }
            !$wait_res;
        } @pids;
    }

    while (@pids) {
        @pids= grep { 
            !waitpid($workers[0],WNOHANG)
        } @pids;
    }

    my $ok=1;
    my $last= 0;
    open my $fh, "<", $out_file
        or die "cant read out_file '$out_file': $!";
    while (<$fh>) {
        if ( /success! got lock (\d+)/ ) {
            $ok=0 unless $1 > $last;
            $last= $1;
        }
    }
    close $fh;
    ok($ok,"We got the expected sequence of worker ids");
}

__END__
