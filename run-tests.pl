#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw( abs_path getcwd );
use File::Basename qw( dirname );
use File::Find qw( find );
use File::Path qw( make_path );
use File::Spec;
use File::Temp qw( tempdir );
use Getopt::Long qw( GetOptions );
use IO::Select;
use IPC::Open3 qw( open3 );
use JSON::PP;
use POSIX qw( strftime );
use Symbol qw( gensym );
use TAP::Parser;
use Time::HiRes qw( time );

my $matrix_root = abs_path( dirname(__FILE__) );
my $default_output_path = File::Spec->catfile(
	$matrix_root,
	'implementation-matrix.json',
);
my $default_browser_output_path = File::Spec->catfile(
	$matrix_root,
	'browser-implementation-matrix.json',
);

my $timeout_seconds = 60;
my $output_path = $default_output_path;
my $browser_output_path = $default_browser_output_path;
my $only_test_pattern;
my $jobs = 4;
my $include_browser = 1;
my $manual_browser = 0;
my $show_browser = 0;
my $include_marshal_interop = 1;
my $browser_bundle_max_age_seconds = 12 * 60 * 60;
my $perl_command;
my $rust_command;
my $js_command;
my $electron_js_command;
my $_marshal_weak_fixtures;
my $_marshal_malformed_fixtures;

$| = 1;
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

GetOptions(
	'timeout=i' => \$timeout_seconds,
	'output=s' => \$output_path,
	'browser-output=s' => \$browser_output_path,
	'only=s' => \$only_test_pattern,
	'jobs=i' => \$jobs,
	'browser!' => \$include_browser,
	'manual-browser' => \$manual_browser,
	'show-browser' => \$show_browser,
	'marshal-interoperability!' => \$include_marshal_interop,
	'perl-cmd=s' => \$perl_command,
	'rust-cmd=s' => \$rust_command,
	'js-cmd=s' => \$js_command,
	'electron-js-cmd=s' => \$electron_js_command,
) or die _usage();

die "--timeout requires an integer >= 1\n"
	if not defined $timeout_seconds or $timeout_seconds < 1;
die "--jobs requires an integer >= 1\n"
	if not defined $jobs or $jobs < 1;
die "--only requires a non-empty pattern\n"
	if defined $only_test_pattern and $only_test_pattern eq '';

my %impl = _implementation_definitions();
_ensure_browser_bundle( $impl{'JS/Node'} ) if $include_browser;

my @ztest_files = _discover_ztest_files( \%impl );
if ( defined $only_test_pattern ) {
	@ztest_files = grep { $_ =~ /$only_test_pattern/ } @ztest_files;
}
@ztest_files = _prioritize_ztest_files(
	ztest_files => \@ztest_files,
	matrix_path => $output_path,
);

if ( scalar @ztest_files == 0 ) {
	my $interop_selected = defined $only_test_pattern
		&& $include_marshal_interop
		&& _marshal_interop_selected($only_test_pattern);
	if ( not $interop_selected ) {
		die "No ztest files selected. Ensure the implementation submodules "
			. "have initialized languagetests/ and stdlib/tests/.\n";
	}
}

_prepare_default_rust_binary( $impl{Rust} );

my %matrix;
if ( scalar @ztest_files > 0 ) {
	%matrix = _build_matrix_parallel(
		implementations => \%impl,
		timeout_seconds => $timeout_seconds,
		ztest_files => \@ztest_files,
		jobs => $jobs,
	);
}

if ($include_marshal_interop) {
	my %marshal_matrix = _build_marshal_interop_matrix(
		implementations => \%impl,
		timeout_seconds => $timeout_seconds,
		only_test_pattern => $only_test_pattern,
	);
	%matrix = ( %matrix, %marshal_matrix );
}

_write_json( $output_path, \%matrix );
print "Wrote $output_path\n";

if ($include_browser) {
	_run_browser_matrix(
		js_impl => $impl{'JS/Node'},
		timeout_seconds => $timeout_seconds,
		output_path => $browser_output_path,
		only_test_pattern => $only_test_pattern,
		manual_browser => $manual_browser,
		show_browser => $show_browser,
	);
}

exit 0;

sub _usage {
	return <<'USAGE';
Usage: ./run-tests.pl [options]

Options:
  --timeout <seconds>       Per-test timeout for each implementation.
  --output <path>           Main JSON output path.
  --browser-output <path>   Browser JSON output path.
  --only <regex>            Include only test paths matching regex.
  --jobs <N>                Number of worker processes (default 4).
  --no-browser              Skip JS/Browser matrix generation.
  --manual-browser          Ask the browser harness to wait for a manual browser.
  --show-browser            Show the Electron browser window.
  --no-marshal-interoperability
                             Skip synthetic std/marshal interop checks.
  --perl-cmd <command>      Perl implementation command prefix.
  --rust-cmd <command>      Rust implementation command prefix.
  --js-cmd <command>        JavaScript Node command prefix.
  --electron-js-cmd <cmd>   JavaScript Electron command prefix.
USAGE
}

sub _implementation_definitions {
	my $perl_root = File::Spec->catdir( $matrix_root, 'implementations', 'zuzu-perl' );
	my $rust_root = File::Spec->catdir( $matrix_root, 'implementations', 'zuzu-rust' );
	my $js_root = File::Spec->catdir( $matrix_root, 'implementations', 'zuzu-js' );

	my $perl_zuzu = File::Spec->catfile( $perl_root, 'bin', 'zuzu' );
	my $rust_zuzu = File::Spec->catfile( $rust_root, 'target', 'debug', 'zuzu-rust' );
	my $js_zuzu = File::Spec->catfile( $js_root, 'bin', 'zuzu-js' );
	my $electron_zuzu = File::Spec->catfile( $js_root, 'bin', 'zuzu-js-electron' );
	my $electron_bin = File::Spec->catfile( $js_root, 'node_modules', '.bin', 'electron' );

	return (
		'Perl' => {
			root => $perl_root,
			command => $perl_command
				// $^X . ' bin/zuzu -Istdlib/test-modules',
			zuzu => $perl_zuzu,
		},
		'Rust' => {
			root => $rust_root,
			command => $rust_command
				// _shell_quote($rust_zuzu) . ' -Istdlib/test-modules',
			zuzu => $rust_zuzu,
		},
		'JS/Node' => {
			root => $js_root,
			command => $js_command
				// 'node bin/zuzu-js -Istdlib/test-modules',
			zuzu => $js_zuzu,
		},
		'JS/Electron' => {
			root => $js_root,
			command => $electron_js_command
				// _shell_quote($electron_bin) . ' bin/zuzu-js-electron -Istdlib/test-modules',
			zuzu => $electron_zuzu,
			prerequisite => $electron_bin,
		},
	);
}

sub _prepare_default_rust_binary {
	my ($rust) = @_;
	return if defined $rust_command;
	return if -x $rust->{zuzu};
	return if not -d $rust->{root};

	print "Building Rust implementation binary...\n";
	my $result = _run_with_timeout(
		command_prefix => 'cargo build --quiet --bin zuzu-rust 2>&1',
		cwd => $rust->{root},
		timeout_seconds => 600,
		zuzu_env => $rust->{zuzu},
	);
	if ( $result->{exit_code} != 0 or not -x $rust->{zuzu} ) {
		die "Could not build Rust implementation binary:\n$result->{stdout}\n";
	}
	return;
}

sub _ensure_browser_bundle {
	my ($js_impl) = @_;
	my $js_root = $js_impl->{root};
	my $build_script = File::Spec->catfile( $js_root, 'bin', 'build-browser-bundle' );
	my $bundle_path = File::Spec->catfile( $js_root, 'dist', 'zuzu-browser.js' );

	if ( not -x $build_script ) {
		die "Cannot build JS/Browser bundle: missing $build_script\n";
	}

	return if _browser_bundle_is_fresh($bundle_path);

	my $reason = -f $bundle_path
		? 'older than 12 hours'
		: 'missing';
	print "Building JS/Browser bundle ($reason)...\n";
	my $result = _run_with_timeout(
		command_prefix => './bin/build-browser-bundle 2>&1',
		cwd => $js_root,
		timeout_seconds => 900,
		zuzu_env => $js_impl->{zuzu},
	);
	if ( $result->{exit_code} != 0 or not -f $bundle_path ) {
		die "Could not build JS/Browser bundle:\n$result->{stdout}\n";
	}

	return;
}

sub _browser_bundle_is_fresh {
	my ($bundle_path) = @_;
	return 0 if not -f $bundle_path;

	my @stat = stat($bundle_path);
	return 0 if not @stat;

	my $mtime = $stat[9];
	return ( time() - $mtime ) <= $browser_bundle_max_age_seconds ? 1 : 0;
}

sub _discover_ztest_files {
	my ($implementations) = @_;
	my @roots = map { $implementations->{$_}{root} } qw( JS/Node Perl Rust );
	my %seen;

	for my $repo_root (@roots) {
		next if not -d $repo_root;
		for my $dir (qw( languagetests stdlib/tests )) {
			my $abs_dir = File::Spec->catdir( $repo_root, split m{/}, $dir );
			next if not -d $abs_dir;
			find(
				{
					no_chdir => 1,
					wanted => sub {
						return if -d $_;
						return if $_ !~ /\.zzs\z/;
						my $rel = File::Spec->abs2rel( $_, $repo_root );
						$rel =~ s{\\}{/}g;
						$seen{$rel} = 1;
					},
				},
				$abs_dir,
			);
		}
		last if keys %seen;
	}

	return sort keys %seen;
}

sub _prioritize_ztest_files {
	my (%args) = @_;
	my @ztest_files = @{ $args{ztest_files} };
	my $matrix = _load_existing_matrix( $args{matrix_path} );
	return @ztest_files if not defined $matrix;

	my @priority;
	my @normal;
	for my $test_path (@ztest_files) {
		if ( _test_is_priority( $matrix->{$test_path} ) ) {
			push @priority, $test_path;
			next;
		}
		push @normal, $test_path;
	}

	return ( @priority, @normal );
}

sub _load_existing_matrix {
	my ($matrix_path) = @_;
	return if not defined $matrix_path;
	return if not -f $matrix_path;

	my $matrix_json = eval { _read_utf8($matrix_path) };
	return if not defined $matrix_json;

	my $matrix = eval { JSON::PP->new->decode($matrix_json) };
	return if not defined $matrix;
	return if ref($matrix) ne 'HASH';

	return $matrix;
}

sub _test_is_priority {
	my ($test_result) = @_;
	return 0 if ref($test_result) ne 'HASH';

	for my $impl_result ( values %{$test_result} ) {
		next if ref($impl_result) ne 'HASH';
		return 1 if _impl_result_is_priority($impl_result);
	}

	return 0;
}

sub _impl_result_is_priority {
	my ($impl_result) = @_;
	return 1
		if defined $impl_result->{status}
		and $impl_result->{status} eq 'hard_fail';

	return 1
		if defined $impl_result->{elapsed}
		and $impl_result->{elapsed} =~ /\A[0-9]+(?:\.[0-9]+)?\z/
		and $impl_result->{elapsed} > 10;

	return 0;
}

sub _build_matrix_parallel {
	my (%args) = @_;
	my @ztest_files = @{ $args{ztest_files} };
	my $worker_count = $args{jobs};
	$worker_count = scalar @ztest_files if $worker_count > scalar @ztest_files;

	my $tmp_dir = tempdir( 'matrix-workers-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
	my @worker_pids;
	my @task_writers;
	my @ready_readers;
	my %worker_by_fileno;

	for my $worker_index ( 0 .. $worker_count - 1 ) {
		pipe( my $task_reader, my $task_writer )
			or die "task pipe for worker $worker_index: $!";
		pipe( my $ready_reader, my $ready_writer )
			or die "ready pipe for worker $worker_index: $!";

		my $pid = fork();
		defined $pid or die "Could not fork worker $worker_index: $!";

		if ( $pid == 0 ) {
			close $task_writer;
			close $ready_reader;
			my %worker_matrix;

			{
				my $old_sel = select($ready_writer);
				$| = 1;
				select($old_sel);
			}

			while (1) {
				print {$ready_writer} "READY\n"
					or die "Could not notify parent from worker $worker_index: $!";

				my $test_path = <$task_reader>;
				last if not defined $test_path;
				chomp $test_path;
				next if $test_path eq '';

				my %test_results;
				for my $name (qw( Perl Rust JS/Node JS/Electron )) {
					$test_results{$name} = _evaluate_impl(
						$args{implementations}{$name},
						$args{timeout_seconds},
						$test_path,
						$name,
						$worker_index,
					);
				}
				$worker_matrix{$test_path} = \%test_results;
			}

			close $task_reader;
			close $ready_writer;

			my $worker_path = File::Spec->catfile( $tmp_dir, "worker-$worker_index.json" );
			_write_json( $worker_path, \%worker_matrix );
			exit 0;
		}

		push @worker_pids, $pid;
		push @task_writers, $task_writer;
		push @ready_readers, $ready_reader;
		$worker_by_fileno{ fileno($ready_reader) } = $worker_index;

		close $task_reader;
		close $ready_writer;

		{
			my $old_sel = select($task_writer);
			$| = 1;
			select($old_sel);
		}
	}

	my $ready_select = IO::Select->new(@ready_readers);
	my @pending_tests = @ztest_files;
	my %worker_closed;

	while ( $ready_select->count ) {
		for my $fh ( $ready_select->can_read ) {
			my $worker_index = $worker_by_fileno{ fileno($fh) };
			my $message = <$fh>;

			if ( not defined $message ) {
				$ready_select->remove($fh);
				close $fh;
				next;
			}

			chomp $message;
			next if $message ne 'READY';

			if (@pending_tests) {
				my $test_path = shift @pending_tests;
				print { $task_writers[$worker_index] } $test_path, "\n"
					or die "Could not send work to worker $worker_index: $!";
				next;
			}

			next if $worker_closed{$worker_index}++;
			close $task_writers[$worker_index];
			$ready_select->remove($fh);
			close $fh;
		}
	}

	for my $pid (@worker_pids) {
		my $waited = waitpid( $pid, 0 );
		die "waitpid failed for worker pid $pid: $!"
			if $waited <= 0;
		my $exit_code = $? >> 8;
		die "worker pid $pid exited with status $exit_code"
			if $exit_code != 0;
	}

	my %matrix;
	for my $worker_index ( 0 .. $worker_count - 1 ) {
		my $worker_path = File::Spec->catfile( $tmp_dir, "worker-$worker_index.json" );
		my $worker_data = JSON::PP->new->decode( _read_utf8($worker_path) );
		%matrix = ( %matrix, %{$worker_data} );
	}

	return %matrix;
}

sub _evaluate_impl {
	my ( $impl, $timeout, $test_path, $name, $worker_ix ) = @_;

	if ( defined $impl->{prerequisite} and not -x $impl->{prerequisite} ) {
		my $now = _iso8601_utc_now();
		return {
			status => 'soft_fail',
			reason => 'skip: missing prerequisite ' . $impl->{prerequisite},
			output => "1..0 # SKIP missing prerequisite $impl->{prerequisite}\n",
			started => $now,
			finished => $now,
			elapsed => 0,
		};
	}

	my $abs_test_path = File::Spec->catfile( $impl->{root}, split m{/}, $test_path );
	if ( not -f $abs_test_path ) {
		my $now = _iso8601_utc_now();
		return {
			status => 'hard_fail',
			reason => 'missing test file',
			output => "Missing test file: $abs_test_path\n",
			started => $now,
			finished => $now,
			elapsed => 0,
		};
	}

	my $result = _run_with_timeout(
		command_prefix => $impl->{command} . ' ' . _shell_quote($test_path) . ' 2>&1',
		cwd => $impl->{root},
		timeout_seconds => $timeout,
		zuzu_env => $impl->{zuzu},
	);
	my $assessed = _assess_command_result( $result, $timeout );

	printf "[%02d] %-12s %s  %-56s (%s; %0.3fs)\n",
		$worker_ix + 1,
		$name,
		_status_symbol( $assessed->{status} ),
		$test_path,
		$assessed->{reason},
		$assessed->{elapsed};

	return $assessed;
}

sub _assess_command_result {
	my ( $result, $timeout ) = @_;

	if ( $result->{timed_out} ) {
		return {
			status => 'hard_fail',
			reason => "timeout >${timeout}s",
			output => $result->{stdout},
			started => $result->{started},
			finished => $result->{finished},
			elapsed => $result->{elapsed},
		};
	}

	my $tap_assessment = _assess_tap( $result->{stdout} );
	my $status = $tap_assessment->{status};
	my $reason = $tap_assessment->{reason};

	if ( $result->{exit_code} != 0 ) {
		$status = 'hard_fail';
		$reason = 'exit ' . $result->{exit_code};
	}

	return {
		status => $status,
		reason => $reason,
		output => $result->{stdout},
		started => $result->{started},
		finished => $result->{finished},
		elapsed => $result->{elapsed},
	};
}

sub _run_browser_matrix {
	my (%args) = @_;
	my $js_root = $args{js_impl}{root};
	my $bundle_path = File::Spec->catfile( $js_root, 'dist', 'zuzu-browser.js' );
	my $harness = File::Spec->catfile(
		$js_root,
		'bin',
		'generate-browser-implementation-matrix-json',
	);
	my $electron = File::Spec->catfile( $js_root, 'node_modules', '.bin', 'electron' );

	if ( not -x $harness ) {
		print "Skipping JS/Browser: missing $harness\n";
		return;
	}
	if ( not -f $bundle_path ) {
		print "Skipping JS/Browser: missing $bundle_path\n";
		return;
	}
	if ( not $args{manual_browser} and not -x $electron ) {
		print "Skipping JS/Browser: missing $electron\n";
		return;
	}

	my @parts = (
		'node',
		_shell_quote('bin/generate-browser-implementation-matrix-json'),
		'--timeout',
		_shell_quote( $args{timeout_seconds} ),
		'--output',
		_shell_quote( $args{output_path} ),
	);
	push @parts, ( '--only', _shell_quote( $args{only_test_pattern} ) )
		if defined $args{only_test_pattern};
	push @parts, '--manual-browser' if $args{manual_browser};
	push @parts, '--show' if $args{show_browser};

	my $result = _run_with_timeout(
		command_prefix => join( ' ', @parts ) . ' 2>&1',
		cwd => $js_root,
		timeout_seconds => 86_400,
		zuzu_env => $args{js_impl}{zuzu},
	);
	if ( $result->{exit_code} != 0 ) {
		die "JS/Browser matrix generation failed:\n$result->{stdout}\n";
	}
	print $result->{stdout};
	return;
}

sub _marshal_interop_selected {
	my ($only_test_pattern) = @_;
	return 1 if not defined $only_test_pattern;

	for my $name ( _marshal_interop_test_names() ) {
		return 1 if $name =~ /$only_test_pattern/;
	}

	return 0;
}

sub _marshal_interop_test_names {
	my @names;
	for my $dump_impl (qw( perl rust js-node )) {
		for my $fixture ( _marshal_positive_fixture_names() ) {
			push @names, "marshall-interop/$dump_impl-dump/$fixture.zzs";
		}
	}
	for my $fixture ( @{ _marshal_weak_fixtures()->{fixtures} || [] } ) {
		next if ref($fixture) ne 'HASH';
		next if not defined $fixture->{name};
		push @names, "marshall-interop/weak-records/$fixture->{name}.zzs";
	}
	for my $fixture ( @{ _marshal_malformed_fixtures() } ) {
		push @names, "marshall-interop/malformed/$fixture->{name}.zzs";
	}
	return @names;
}

sub _marshal_positive_fixture_names {
	return qw(
		scalar-null
		array-cycle
		dict-pairlist
		time-path
		function
		class
		trait
		object-instance
		worker-payload-plain
		worker-payload-result
	);
}

sub _build_marshal_interop_matrix {
	my (%args) = @_;
	my $impl = $args{implementations};
	my %dump_impls = (
		perl => {
			display => 'Perl',
			impl => $impl->{Perl},
		},
		rust => {
			display => 'Rust',
			impl => $impl->{Rust},
		},
		'js-node' => {
			display => 'JS/Node',
			impl => $impl->{'JS/Node'},
		},
	);
	my %load_impls = (
		'Perl' => $impl->{Perl},
		'Rust' => $impl->{Rust},
		'JS/Node' => $impl->{'JS/Node'},
		'JS/Electron' => $impl->{'JS/Electron'},
	);
	my $tmp_dir = tempdir( 'marshal-interop-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
	my %matrix;

	for my $dump_slug (qw( perl rust js-node )) {
		for my $fixture_name ( _marshal_positive_fixture_names() ) {
			my $test_name = "marshall-interop/$dump_slug-dump/$fixture_name.zzs";
			next if defined $args{only_test_pattern}
				and $test_name !~ /$args{only_test_pattern}/;

			my $blob_result = $dump_slug eq 'perl'
				&& _marshal_fixture_has_golden($fixture_name)
				? _marshal_golden_blob($fixture_name)
				: _marshal_generate_blob(
					timeout_seconds => $args{timeout_seconds},
					impl => $dump_impls{$dump_slug}{impl},
					fixture_name => $fixture_name,
					tmp_dir => $tmp_dir,
				);

			my %results;
			for my $loader (qw( Perl Rust JS/Node JS/Electron )) {
				if ( $blob_result->{status} ne 'pass' ) {
					$results{$loader} = {
						status => 'hard_fail',
						reason => "$dump_impls{$dump_slug}{display} dump failed",
						output => $blob_result->{output} // '',
						started => $blob_result->{started},
						finished => $blob_result->{finished},
						elapsed => $blob_result->{elapsed} // 0,
					};
					next;
				}
				$results{$loader} = _evaluate_marshal_source(
					timeout_seconds => $args{timeout_seconds},
					impl => $load_impls{$loader},
					source => _marshal_positive_load_source(
						$fixture_name,
						$blob_result->{blob},
					),
					name => "$dump_impls{$dump_slug}{display} dump -> $loader load",
					test_name => $test_name,
					tmp_dir => $tmp_dir,
				);
			}
			$results{'JS/Browser'} = _marshal_browser_skip_result();
			$matrix{$test_name} = \%results;
		}
	}

	for my $fixture ( @{ _marshal_weak_fixtures()->{fixtures} || [] } ) {
		next if ref($fixture) ne 'HASH';
		next if not defined $fixture->{name};
		my $test_name = "marshall-interop/weak-records/$fixture->{name}.zzs";
		next if defined $args{only_test_pattern}
			and $test_name !~ /$args{only_test_pattern}/;

		my %results;
		for my $loader (qw( Perl Rust JS/Node JS/Electron )) {
			$results{$loader} = _evaluate_marshal_source(
				timeout_seconds => $args{timeout_seconds},
				impl => $load_impls{$loader},
				source => _marshal_weak_load_source($fixture),
				name => "weak fixture -> $loader load",
				test_name => $test_name,
				tmp_dir => $tmp_dir,
			);
		}
		$results{'JS/Browser'} = _marshal_browser_skip_result();
		$matrix{$test_name} = \%results;
	}

	for my $fixture ( @{ _marshal_malformed_fixtures() } ) {
		my $test_name = "marshall-interop/malformed/$fixture->{name}.zzs";
		next if defined $args{only_test_pattern}
			and $test_name !~ /$args{only_test_pattern}/;

		my %results;
		for my $loader (qw( Perl Rust JS/Node JS/Electron )) {
			$results{$loader} = _evaluate_marshal_source(
				timeout_seconds => $args{timeout_seconds},
				impl => $load_impls{$loader},
				source => _marshal_malformed_load_source($fixture),
				name => "malformed fixture -> $loader load",
				test_name => $test_name,
				tmp_dir => $tmp_dir,
			);
		}
		$results{'JS/Browser'} = _marshal_browser_skip_result();
		$matrix{$test_name} = \%results;
	}

	return %matrix;
}

sub _marshal_browser_skip_result {
	my $now = _iso8601_utc_now();
	return {
		status => 'soft_fail',
		reason => 'skip: marshal interoperability is covered by CLI runtimes',
		output => "1..0 # SKIP marshal interoperability is covered by CLI runtimes\n",
		started => $now,
		finished => $now,
		elapsed => 0,
	};
}

sub _marshal_golden_blob {
	my ($fixture_name) = @_;
	my $path = File::Spec->catfile(
		$matrix_root,
		'implementations',
		'zuzu-perl',
		't',
		'fixtures',
		'marshal',
		'golden',
		"$fixture_name.b64",
	);
	my $started = _iso8601_utc_now();
	my $started_ts = time();
	my $blob = eval { _read_utf8($path) };
	if ( not defined $blob ) {
		return {
			status => 'hard_fail',
			reason => "missing golden fixture $fixture_name",
			output => $@ || '',
			started => $started,
			finished => _iso8601_utc_now(),
			elapsed => time() - $started_ts,
		};
	}
	$blob =~ s/\s+\z//;
	return {
		status => 'pass',
		blob => $blob,
		output => "$blob\n",
		started => $started,
		finished => _iso8601_utc_now(),
		elapsed => time() - $started_ts,
	};
}

sub _marshal_generate_blob {
	my (%args) = @_;
	my $fixture_name = $args{fixture_name};
	my $body = _marshal_fixture_body($fixture_name);
	my $source = <<~"ZUZU";
		from std/marshal import dump;
		from std/string/base64 import encode;
		$body
		say( encode( dump(fixture_value) ) );
		ZUZU

	my $result = _run_marshal_source(
		timeout_seconds => $args{timeout_seconds},
		impl => $args{impl},
		source => $source,
		tmp_dir => $args{tmp_dir},
		name => "$fixture_name-dump",
	);
	my $blob = $result->{stdout};
	$blob =~ s/\s+\z// if defined $blob;
	if (
		$result->{exit_code} != 0
		or not defined $blob
		or $blob !~ /\A[A-Za-z0-9+\/=]+\z/
	) {
		return {
			status => 'hard_fail',
			reason => $result->{timed_out}
				? "timeout >$args{timeout_seconds}s"
				: 'dump did not emit base64',
			output => $result->{stdout},
			started => $result->{started},
			finished => $result->{finished},
			elapsed => $result->{elapsed},
		};
	}

	return {
		status => 'pass',
		blob => $blob,
		output => $result->{stdout},
		started => $result->{started},
		finished => $result->{finished},
		elapsed => $result->{elapsed},
	};
}

sub _marshal_fixture_has_golden {
	my ($fixture_name) = @_;
	my %golden = map { $_ => 1 } qw(
		scalar-null
		array-cycle
		dict-pairlist
		time-path
		function
		class
		trait
		object-instance
	);
	return $golden{$fixture_name} ? 1 : 0;
}

sub _marshal_fixture_body {
	my ($fixture_name) = @_;
	my %bodies = (
		'scalar-null' => q{
			let fixture_value := null;
		},
		'array-cycle' => q{
			let fixture_value := [];
			fixture_value.push(fixture_value);
		},
		'dict-pairlist' => q{
			let fixture_value := [
				{ beta: 2, alpha: 1 },
				{{ foo: 1, bar: 2, foo: 3 }},
			];
		},
		'time-path' => q{
			from std/time import Time;
			from std/io import Path;
			let fixture_value := [
				new Time(12345),
				new Path("tmp/../file.txt"),
			];
		},
		'function' => q{
			function add_one (x) {
				return x + 1;
			}
			let fixture_value := add_one;
		},
		'class' => q{
			const offset := 40;
			class GoldenPoint {
				let Number x := 1;

				method total (Number y) -> Number {
					return x + y + offset;
				}
			}
			let fixture_value := GoldenPoint;
		},
		'trait' => q{
			const prefix := "label:";
			trait GoldenLabelled {
				method label () -> String {
					return prefix _ self.get_name();
				}
			}
			let fixture_value := GoldenLabelled;
		},
		'object-instance' => q{
			class GoldenBox {
				let String name with get, set := "unset";
				const kind := "box";

				method label () {
					return name _ ":" _ kind;
				}
			}
			let fixture_value := new GoldenBox( name: "Ada" );
		},
		'worker-payload-plain' => q{
			function marshal_worker_add ( x, y ) {
				return x + y;
			}

			trait MarshalWorkerLabelled {
				method label () {
					return "box:" _ self.get_name();
				}
			}

			class MarshalWorkerBox with MarshalWorkerLabelled {
				let String name with get, set := "unset";
			}

			let fixture_value := {
				callable: marshal_worker_add,
				args: [ 20, 22 ],
				returned: {
					scalar: "plain",
					collection: [ 1, { name: "Ada" } ],
					object: new MarshalWorkerBox( name: "Ada" ),
					class: MarshalWorkerBox,
					trait: MarshalWorkerLabelled,
				},
			};
		},
		'worker-payload-result' => q{
			from std/result import Result;

			let fixture_value := {
				ok: Result.ok(42),
				err: Result.err("worker-boom"),
			};
		},
	);
	die "Unknown marshal fixture '$fixture_name'\n"
		if not exists $bodies{$fixture_name};
	return $bodies{$fixture_name};
}

sub _marshal_positive_load_source {
	my ( $fixture_name, $blob ) = @_;
	my %checks = (
		'scalar-null' => [
			'v == null',
			'null root loads',
		],
		'array-cycle' => [
			'typeof v == "Array"',
			'Array root loads',
			'ref_id(v) == ref_id(v[0])',
			'Array cycle is preserved',
		],
		'dict-pairlist' => [
			'v[0]{alpha} == 1',
			'Dict item loads',
			'v[1].get_all("foo") == [ 1, 3 ]',
			'PairList duplicate keys load',
		],
		'time-path' => [
			'v[0].epoch() == 12345',
			'Time item loads',
			'v[1].to_String() == "tmp/../file.txt"',
			'Path item loads',
		],
		'function' => [
			'typeof v == "Function"',
			'Function root loads',
			'v(41) == 42',
			'Function executes after load',
		],
		'class' => [
			'typeof v == "Class"',
			'Class root loads',
			'( new v( x: 1 ) ).total(1) == 42',
			'Class method executes after load',
		],
		'trait' => [
			'v != null',
			'Trait root loads as a usable value',
			'( new MarshalInteropTraitUser() ).label() == "label:Bea"',
			'Trait method composes after load',
		],
		'object-instance' => [
			'typeof v == "GoldenBox"',
			'Object instance root loads',
			'v.label() == "Ada:box"',
			'Object instance method executes after load',
		],
		'worker-payload-plain' => [
			'v{callable}( v{args}[0], v{args}[1] ) == 42',
			'Worker callable payload executes after load',
			'v{returned}{scalar} == "plain"',
			'Worker scalar return payload loads',
			'v{returned}{collection}[1]{name} == "Ada"',
			'Worker collection return payload loads',
			'typeof v{returned}{object} == "MarshalWorkerBox"',
			'Worker object return payload loads',
			'v{returned}{object}.label() == "box:Ada"',
			'Worker object method executes after load',
			'typeof v{returned}{class} == "Class"',
			'Worker class return payload loads',
			'( new v{returned}{class}( name: "Bea" ) ).label() == "box:Bea"',
			'Worker class payload constructs usable objects',
			'v{returned}{trait} != null',
			'Worker trait return payload loads',
		],
		'worker-payload-result' => [
			'typeof v{ok} == "Result"',
			'Result.ok worker payload loads',
			'v{ok}.unwrap() == 42',
			'Result.ok worker payload unwraps',
			'typeof v{err} == "Result"',
			'Result.err worker payload loads',
			'v{err}.unwrap_err() == "worker-boom"',
			'Result.err worker payload unwrap_err works',
		],
	);
	my @pairs = @{ $checks{$fixture_name} };
	my $plan = @pairs / 2;
	my $trait_setup = $fixture_name eq 'trait'
		? <<'ZUZU'
class MarshalInteropTraitUser with v {
	let String name with get := "Bea";
}
ZUZU
		: '';
	my @test_lines;
	for ( my $i = 0; $i < @pairs; $i += 2 ) {
		my $number = ( $i / 2 ) + 1;
		my $expr = $pairs[$i];
		my $label = $pairs[ $i + 1 ];
		push @test_lines,
			qq{if ( $expr ) { say("ok $number - $label"); }\n}
			. qq{else { say("not ok $number - $label"); }};
	}
	my $tests = join "\n", @test_lines;

	return <<~"ZUZU";
		from std/marshal import load;
		from std/string/base64 import decode;
		from std/internals import ref_id;

		let v := load( decode("$blob") );
		$trait_setup
		say("1..$plan");
		$tests
		ZUZU
}

sub _marshal_weak_fixtures {
	return $_marshal_weak_fixtures if defined $_marshal_weak_fixtures;

	my $path = File::Spec->catfile(
		$matrix_root,
		'implementations',
		'zuzu-perl',
		't',
		'fixtures',
		'marshal',
		'weak-records.json',
	);
	$_marshal_weak_fixtures = JSON::PP->new->decode( _read_utf8($path) );
	return $_marshal_weak_fixtures;
}

sub _marshal_weak_load_source {
	my ($fixture) = @_;
	my $name = $fixture->{name};
	my $blob = $fixture->{base64};
	my $expect = $fixture->{expect} || 'reject';

	if ( $expect eq 'loads' ) {
		return <<~"ZUZU";
			from std/marshal import load;
			from std/string/base64 import decode;

			load( decode("$blob") );
			say("1..1");
			say("ok 1 - $name loads");
			ZUZU
	}

	return <<~"ZUZU";
		from std/marshal import load, UnmarshallingException;
		from std/string/base64 import decode;

		say("1..1");
		try {
			load( decode("$blob") );
			say("not ok 1 - $name rejects reserved weak storage");
		}
		catch ( UnmarshallingException e ) {
			say("ok 1 - $name rejects reserved weak storage");
		}
		ZUZU
}

sub _marshal_malformed_fixtures {
	return $_marshal_malformed_fixtures
		if defined $_marshal_malformed_fixtures;

	$_marshal_malformed_fixtures = [
		{
			name => 'invalid-cbor-trailing-bytes',
			base64 => '9gA=',
		},
		{
			name => 'wrong-envelope-magic',
			base64 => '2dn3hnBOT1QtWlVaVS1NQVJTSEFMAaD2gIA=',
		},
		{
			name => 'wrong-envelope-arity',
			base64 => '2dn3hWxaVVpVLU1BUlNIQUwBoPaA',
		},
		{
			name => 'wrong-envelope-options',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBgPaAgA==',
		},
		{
			name => 'wrong-version',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwCoPaAgA==',
		},
		{
			name => 'invalid-object-reference',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoIIAAYGCAoCA',
		},
		{
			name => 'unsupported-object-kind',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoIIAAIGCGGOAgA==',
		},
		{
			name => 'duplicate-dict-keys',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoIIAAIGCA4KCY2R1cAGCY2R1cAKA',
		},
		{
			name => 'duplicate-slot-names',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoIIAAIKCB4KCAAGCgmF4AYJheAKCCYEAgYUCbU1hcnNoYWxCYWRCb3h4P2NsYXNzIE1hcnNoYWxCYWRCb3ggeyBsZXQgeDsgbWV0aG9kIGxhYmVsICgpIHsgcmV0dXJuICJvayI7IH0gfYCA',
		},
		{
			name => 'invalid-code-reference',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoIIAAIGCCIEBgA==',
		},
		{
			name => 'unsupported-code-kind',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoPaAgYUYY25tYXJzaGFsX2JhZF9mbngZZnVuY3Rpb24gKCkgeyByZXR1cm4gMTsgfYCA',
		},
		{
			name => 'invalid-code-dependency',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoPaAgYUCbU1hcnNoYWxCYWRCb3h4P2NsYXNzIE1hcnNoYWxCYWRCb3ggeyBsZXQgeDsgbWV0aG9kIGxhYmVsICgpIHsgcmV0dXJuICJvayI7IH0gfYCBggAB',
		},
		{
			name => 'malformed-code-capture',
			base64 => '2dn3hmxaVVpVLU1BUlNIQUwBoIIAAIGCCIEAgYUBbm1hcnNoYWxfYmFkX2ZueBlmdW5jdGlvbiAoKSB7IHJldHVybiAxOyB9gYNjY2FwAQKA',
		},
	];
	return $_marshal_malformed_fixtures;
}

sub _marshal_malformed_load_source {
	my ($fixture) = @_;
	my $name = $fixture->{name};
	my $blob = $fixture->{base64};

	return <<~"ZUZU";
		from std/marshal import load, UnmarshallingException;
		from std/string/base64 import decode;

		say("1..1");
		try {
			load( decode("$blob") );
			say("not ok 1 - $name rejects malformed marshal blob");
		}
		catch ( UnmarshallingException e ) {
			say("ok 1 - $name rejects malformed marshal blob");
		}
		ZUZU
}

sub _evaluate_marshal_source {
	my (%args) = @_;
	my $impl = $args{impl};
	if ( defined $impl->{prerequisite} and not -x $impl->{prerequisite} ) {
		my $now = _iso8601_utc_now();
		return {
			status => 'soft_fail',
			reason => 'skip: missing prerequisite ' . $impl->{prerequisite},
			output => "1..0 # SKIP missing prerequisite $impl->{prerequisite}\n",
			started => $now,
			finished => $now,
			elapsed => 0,
		};
	}

	my $result = _run_marshal_source(%args);
	my $assessed = _assess_command_result( $result, $args{timeout_seconds} );

	printf "[marshal] %-32s %s  %-56s (%s; %0.3fs)\n",
		$args{name},
		_status_symbol( $assessed->{status} ),
		$args{test_name},
		$assessed->{reason},
		$assessed->{elapsed};

	return $assessed;
}

sub _run_marshal_source {
	my (%args) = @_;
	my $safe_name = $args{name} || 'marshal-interoperability';
	$safe_name =~ s{[^A-Za-z0-9_.-]+}{-}g;
	my $path = File::Spec->catfile(
		$args{tmp_dir},
		$safe_name . '-' . int( rand(1_000_000_000) ) . '.zzs',
	);
	_write_utf8( $path, $args{source} );

	return _run_with_timeout(
		command_prefix => $args{impl}{command} . ' ' . _shell_quote($path) . ' 2>&1',
		cwd => $args{impl}{root},
		timeout_seconds => $args{timeout_seconds},
		zuzu_env => $args{impl}{zuzu},
	);
}

sub _assess_tap {
	my ($stdout) = @_;

	if ( not defined $stdout or $stdout eq '' ) {
		return {
			status => 'hard_fail',
			reason => 'no TAP tests',
		};
	}

	my $tap_parser = eval {
		TAP::Parser->new( { source => \$stdout } );
	};
	if ( not defined $tap_parser ) {
		return {
			status => 'hard_fail',
			reason => 'invalid TAP',
		};
	}
	my @not_ok;
	my $tests_seen = 0;
	my $skip_all = 0;
	my $skip_reason = '';

	while ( my $result = $tap_parser->next ) {
		if ( $result->is_test ) {
			$tests_seen++;
			next if $result->is_ok;
			push @not_ok, $result;
			next;
		}
		if (
			$result->is_plan
			and $result->can('tests_planned')
			and $result->tests_planned == 0
			and $result->can('directive')
			and defined $result->directive
			and $result->directive eq 'SKIP'
		) {
			$skip_all = 1;
			if (
				$result->can('explanation')
				and defined $result->explanation
				and $result->explanation ne ''
			) {
				$skip_reason = $result->explanation;
			}
		}
	}

	if ( $tests_seen == 0 ) {
		if ($skip_all) {
			return {
				status => 'soft_fail',
				reason => $skip_reason ne '' ? "skip: $skip_reason" : 'skip',
			};
		}
		return {
			status => 'soft_fail',
			reason => 'no tests',
		};
	}

	if ( not $tap_parser->is_good_plan or $tap_parser->has_problems ) {
		return {
			status => 'hard_fail',
			reason => 'invalid TAP',
		};
	}

	if ( scalar @not_ok == 0 ) {
		return {
			status => 'pass',
			reason => 'ok',
		};
	}

	my $todo_or_skip_only = 1;
	for my $result (@not_ok) {
		my $directive = $result->directive;
		if ( not defined $directive ) {
			$todo_or_skip_only = 0;
			last;
		}
		if ( $directive ne 'TODO' and $directive ne 'SKIP' ) {
			$todo_or_skip_only = 0;
			last;
		}
	}

	return {
		status => 'soft_fail',
		reason => 'todo/skip in TAP',
	} if $todo_or_skip_only;

	return {
		status => 'hard_fail',
		reason => 'not ok in TAP',
	};
}

sub _status_symbol {
	my ($status) = @_;
	return '✅' if defined $status and $status eq 'pass';
	return '🟡' if defined $status and $status eq 'soft_fail';
	return '❌' if defined $status and $status eq 'hard_fail';
	return '❌';
}

sub _run_with_timeout {
	my (%args) = @_;
	my $stdout = '';
	my $timed_out = 0;
	my $exit_code;
	my $old_cwd = getcwd();

	chdir $args{cwd} or die "Could not chdir to $args{cwd}: $!";
	local $ENV{ZUZU} = $args{zuzu_env} if defined $args{zuzu_env};

	my $started = _iso8601_utc_now();
	my $started_ts = time();
	my @cmd = ( 'bash', '-lc', $args{command_prefix} );
	my $stderr = gensym;
	my $pid = open3( undef, my $stdout_fh, $stderr, @cmd );

	eval {
		local $SIG{ALRM} = sub {
			die "TIMEOUT\n";
		};
		alarm $args{timeout_seconds};
		$stdout = do {
			local $/;
			<$stdout_fh>;
		};
		waitpid( $pid, 0 );
		alarm 0;
		1;
	} or do {
		my $error = $@;
		if ( defined $error and $error =~ /TIMEOUT/ ) {
			$timed_out = 1;
			kill 'TERM', $pid;
			waitpid( $pid, 0 );
		}
		else {
			die $error;
		}
	};

	if ( not $timed_out ) {
		$exit_code = $? >> 8;
	}
	else {
		$exit_code = 124;
	}

	chdir $old_cwd or die "Could not restore cwd to $old_cwd: $!";

	return {
		started => $started,
		finished => _iso8601_utc_now(),
		elapsed => time() - $started_ts,
		timed_out => $timed_out,
		exit_code => $exit_code,
		stdout => defined $stdout ? $stdout : '',
	};
}

sub _iso8601_utc_now {
	return strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
}

sub _shell_quote {
	my ($value) = @_;
	$value = '' if not defined $value;
	$value =~ s/'/'"'"'/g;
	return "'$value'";
}

sub _write_json {
	my ( $path, $data ) = @_;
	my $json = JSON::PP
		->new
		->utf8
		->pretty
		->canonical
		->encode($data);
	_write_utf8( $path, $json );
	return;
}

sub _write_utf8 {
	my ( $path, $content ) = @_;
	my $dir = dirname($path);
	make_path($dir) if defined $dir and $dir ne '' and not -d $dir;
	open my $fh, '>:encoding(UTF-8)', $path
		or die "Could not write $path: $!";
	print {$fh} $content;
	close $fh;
	return;
}

sub _read_utf8 {
	my ($path) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or die "Could not read $path: $!";
	my $content = do {
		local $/;
		<$fh>;
	};
	close $fh;
	return $content;
}
