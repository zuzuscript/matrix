#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw( abs_path );
use File::Basename qw( dirname );
use File::Path qw( make_path );
use File::Spec;
use Getopt::Long qw( GetOptions );
use JSON::PP;
use List::Util qw( min );
use Time::Piece;

my $matrix_root = abs_path( dirname(__FILE__) );
my $json_path = File::Spec->catfile( $matrix_root, 'implementation-matrix.json' );
my $browser_json_path = File::Spec->catfile(
	$matrix_root,
	'browser-implementation-matrix.json',
);
my $markdown_path;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

GetOptions(
	'matrix=s' => \$json_path,
	'browser-matrix=s' => \$browser_json_path,
	'output=s' => \$markdown_path,
) or die _usage();

my $matrix = JSON::PP->new->decode( _slurp_utf8($json_path) );
die "Expected top-level object in $json_path\n"
	if ref $matrix ne 'HASH';

if ( defined $browser_json_path and -f $browser_json_path ) {
	my $browser_matrix = JSON::PP->new->decode( _slurp_utf8($browser_json_path) );
	die "Expected top-level object in $browser_json_path\n"
		if ref $browser_matrix ne 'HASH';
	_merge_matrix( $matrix, $browser_matrix );
}

my @implementations = _sorted_implementations();
my %summary_counts;
for my $impl (@implementations) {
	$summary_counts{$impl} = {
		pass => 0,
		soft_fail => 0,
		timeout => 0,
		hard_fail => 0,
	};
}

my @tests = sort keys %{$matrix};
my $marshal_interop_count = scalar grep {
	$_ =~ m{\Amarshall-interop/}
} @tests;

my @lines;
push @lines, '# Appendix E: Implementation Test Status';
push @lines, '';
push @lines, "The following table indicates how well each version of ZuzuScript implements the language's features and standard library.";
push @lines, '';
if ( $marshal_interop_count > 0 ) {
	push @lines, sprintf(
		'This table includes %d generated `std/marshal` interoperability result rows covering cross-runtime dump/load fixtures, reserved weak-record fixtures, and malformed-blob fixtures.',
		$marshal_interop_count,
	);
	push @lines, '';
}
push @lines, '| Test | ' . join( ' | ', @implementations ) . ' |';
push @lines, '| --- | ' . join( ' | ', map { '---' } @implementations ) . ' |';

for my $test_name (@tests) {
	my @row = ( _markdown_escape($test_name) );

	for my $r ( values %{ $matrix->{$test_name} } ) {
		$r->{elapsed} //= _calculate_elapsed($r)
			if ref $r eq 'HASH';
	}

	my $fastest = min(
		map  { $matrix->{$test_name}{$_}{elapsed} }
		grep {
			ref $matrix->{$test_name}{$_} eq 'HASH'
				and defined $matrix->{$test_name}{$_}{status}
				and $matrix->{$test_name}{$_}{status} eq 'pass'
				and defined $matrix->{$test_name}{$_}{elapsed}
				and $_ ne 'JS/Browser'
		}
		@implementations
	);

	for my $impl (@implementations) {
		my $result = $matrix->{$test_name}{$impl};
		my $is_fastest = (
			ref $result eq 'HASH'
			and defined $fastest
			and defined $result->{elapsed}
			and $result->{elapsed} == $fastest
			and $impl ne 'JS/Browser'
		);
		push @row, _format_status_cell( $impl, $result, $is_fastest );

		my $bucket = _summary_bucket($result);
		$summary_counts{$impl}{$bucket}++;
	}

	push @lines, '| ' . join( ' | ', @row ) . ' |';
}

push @lines, '';
push @lines, '## Summary counts';
push @lines, '';
push @lines, '| Implementation | Pass | Soft fail | Timeout | Hard fail |';
push @lines, '| --- | ---: | ---: | ---: | ---: |';

for my $impl (@implementations) {
	my $counts = $summary_counts{$impl};
	push @lines, sprintf(
		'| %s | %d | %d | %d | %d |',
		$impl,
		$counts->{pass},
		$counts->{soft_fail},
		$counts->{timeout},
		$counts->{hard_fail},
	);
}

my $latest_finished = _latest_finished_timestamp($matrix);
if ( defined $latest_finished ) {
	push @lines, '';
	push @lines, sprintf(
		'Test run completed: `%s`.',
		_markdown_escape($latest_finished),
	);
}

my $markdown = join( "\n", @lines ) . "\n";
if ( defined $markdown_path and $markdown_path ne '' ) {
	_write_utf8( $markdown_path, $markdown );
	print "Wrote $markdown_path\n";
}
else {
	print $markdown;
}

exit 0;

sub _usage {
	return <<'USAGE';
Usage: ./make-markdown.pl [options]

Options:
  --matrix <path>          Main implementation matrix JSON.
  --browser-matrix <path>  Browser implementation matrix JSON to merge.
  --output <path>          Markdown output path. Defaults to stdout.
USAGE
}

sub _sorted_implementations {
	return qw( Perl Rust JS/Node JS/Electron JS/Browser );
}

sub _merge_matrix {
	my ( $matrix, $extra_matrix ) = @_;

	for my $test_name ( keys %{$extra_matrix} ) {
		next if ref $extra_matrix->{$test_name} ne 'HASH';
		$matrix->{$test_name} //= {};
		for my $impl ( keys %{ $extra_matrix->{$test_name} } ) {
			$matrix->{$test_name}{$impl} = $extra_matrix->{$test_name}{$impl};
		}
	}

	return;
}

sub _format_status_cell {
	my ( $impl, $result, $is_fastest ) = @_;

	if ( ref $result ne 'HASH' ) {
		return q{<span class="badge text-bg-danger" title="missing result">missing</span>};
	}

	my $status = $result->{status};
	my $reason = $result->{reason};
	$reason = 'no reason provided' if not defined $reason or $reason eq '';
	my $title = _html_escape($reason);

	if ( defined $status and $status eq 'pass' ) {
		my $elapsed = defined $result->{elapsed} ? $result->{elapsed} : 0;
		my $dot = sprintf(
			' <small title="%0.2f s">%s</small>',
			$elapsed,
			$is_fastest ? '🔵' : '⚪',
		);
		$dot = '' if $impl eq 'JS/Browser';
		return qq{<span class="badge text-bg-success" title="$title">pass$dot</span>};
	}

	if ( defined $status and $status eq 'soft_fail' ) {
		return qq{<span class="badge text-bg-warning" title="$title">skip</span>};
	}

	if ( defined $reason and $reason =~ /^timeout/ ) {
		return qq{<span class="badge text-bg-info" title="$title">time out</span>};
	}

	if ( defined $status and $status eq 'hard_fail' ) {
		return qq{<span class="badge text-bg-danger" title="$title">fail</span>};
	}

	my $display_status = defined $status ? $status : 'unknown';
	my $unknown = _html_escape("unknown status: $display_status");
	return qq{<span class="badge text-bg-danger" title="$unknown">fail</span>};
}

sub _summary_bucket {
	my ($result) = @_;

	return 'hard_fail' if ref $result ne 'HASH';

	my $status = $result->{status};
	return 'pass' if defined $status and $status eq 'pass';
	return 'soft_fail' if defined $status and $status eq 'soft_fail';
	return 'timeout'
		if defined $result->{reason}
		and $result->{reason} =~ /^timeout/;
	return 'hard_fail';
}

sub _calculate_elapsed {
	my ($result) = @_;
	return 300 if ref $result ne 'HASH';
	return 300 if not $result->{started} or not $result->{finished};

	my $elapsed = eval {
		my $s = Time::Piece->strptime( $result->{started}, '%Y-%m-%dT%H:%M:%SZ' );
		my $f = Time::Piece->strptime( $result->{finished}, '%Y-%m-%dT%H:%M:%SZ' );
		$f - $s;
	};
	return defined $elapsed ? $elapsed : 300;
}

sub _latest_finished_timestamp {
	my ($matrix) = @_;
	my $latest;

	for my $test_name ( keys %{$matrix} ) {
		next if ref $matrix->{$test_name} ne 'HASH';
		for my $result ( values %{ $matrix->{$test_name} } ) {
			next if ref $result ne 'HASH';
			next if not defined $result->{finished};
			next if $result->{finished} !~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/;
			$latest = $result->{finished}
				if not defined $latest or $result->{finished} gt $latest;
		}
	}

	return $latest;
}

sub _html_escape {
	my ($text) = @_;
	$text = '' if not defined $text;
	$text =~ s/&/&amp;/g;
	$text =~ s/</&lt;/g;
	$text =~ s/>/&gt;/g;
	$text =~ s/"/&quot;/g;
	return $text;
}

sub _markdown_escape {
	my ($text) = @_;
	$text = '' if not defined $text;
	$text =~ s/\\/\\\\/g;
	$text =~ s/\|/\\|/g;
	return $text;
}

sub _slurp_utf8 {
	my ($path) = @_;
	open my $fh, '<:encoding(UTF-8)', $path
		or die "Could not open $path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
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
