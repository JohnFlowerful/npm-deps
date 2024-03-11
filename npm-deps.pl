#!/usr/bin/env perl
# PODNAME: npm-deps
# ABSTRACT: A helper script for npm based Gentoo ebuilds

# relevant links:
# https://github.com/npm/pacote/tree/main
# https://github.com/NixOS/nixpkgs/tree/master/pkgs/build-support/node/fetch-npm-deps

use strict;
use warnings;

use Cwd qw(abs_path);
use Term::ANSIColor;
use File::Find;
use JSON::PP qw(encode_json decode_json);
use URI ();

use File::Path qw(make_path rmtree);
use File::Temp ();
use IPC::Run3 qw(run3);

use Digest::SHA qw(sha1 sha512 sha256);
use LWP::UserAgent ();
use MIME::Base64 qw(decode_base64 encode_base64);
use File::Basename qw(dirname);

use Getopt::Long qw(GetOptions :config no_auto_abbrev);
Getopt::Long::Configure ('bundling', 'no_ignore_case', 'no_getopt_compat', 'no_auto_abbrev');
use Pod::Usage qw(pod2usage);

use Data::Dumper;

our $VERSION = 1.13;

=head1 SYNOPSIS

npm-deps [action] [options]

  Actions:
    download        Download and verify all dependency archives
        --pack          Tarball dependencies into a single archive once download
                        is complete
        --update        Only download the required dependencies and verify existing
                        dependency integrities.
                        Also asks to delete any files not found in the updated
                        lockfile
        --delete        Don't ask to delete old dependencies
        --no-verify     Disable dependency integrity checks
        --no-cleanup    Don't delete tmpdirs created for git based dependencies

    verify-files    Verify downloaded archives against package-lock.json's 
                    integrity string

    cacache         Generate an npm compatible cacache structure

    fixup-lockfile  Fix potential issues in package-lock.json

  General options:
    --lockfile      Set the location of package-lock.json file
    --verbose       Show what's happening
    -h, --help      Show this help message
    -V, --version   Show script version
=cut

# cleanup on signal
for my $signal (qw/HUP INT QUIT TERM/) {
	$SIG{$signal} = \&trap_cleanup;
}

# hashes used for options and actions
my (%opt, %act);

# variables set by env eventually
my $cwd = Cwd::abs_path();
my $deps_dir = "$cwd/npm-deps";

# output things
my $prefix_str='*';
my $output_prefix = colored(['green'], $prefix_str, color('reset'));
my $warn_prefix = colored(['yellow'], $prefix_str, color('reset'));
my $err_prefix = colored(['red'], $prefix_str, color('reset'));
my $query_str='>';
my $query_prefix = colored(['green'], $query_str, color('reset'));

sub main {
	OptionsHandler::get();

	my $lockfile = ($opt{'lockfile'} || 'package-lock.json');
	my $lock_content = Util::read_file_as($lockfile, 'encoding(UTF-8)');

	# do this before loading up @packages
	if ($act{'fixup-lockfile'}) {
		my $data = fixup_lockfile($lock_content);
		# it wont be pretty~
		Util::write_file($lockfile, JSON::PP::encode_json($$data)) if $data;
	}
	else {
		my $packages = lockfile($lock_content, $ENV{'FORCE_GIT_DEPS'}, $ENV{'FORCE_EMPTY_CACHE'});

		if ($act{'download'}) {
			mkdir $deps_dir;
			if (!Util::is_empty_dir($deps_dir)) {
				warning("Warning: $deps_dir directory exists");
				$opt{'update'} = 1 if Util::prompt_yn("Do you want to update it");

				error_handler('dir-not-empty', $deps_dir) if !$opt{'update'};

				my ($found, $not_found) = compare_dir_to_lockfile($deps_dir, @$packages);

				@$packages = @$not_found;

				if ($opt{'verify'}) {
					for my $pkg (values @$found) {
						my $data = Util::fetch($pkg->{'filename'});
						if (!$pkg->verify($data)) {
							if ($opt{'delete'} || Util::prompt_yn("Do you want to re-download this package")) {
								push(@$packages, $pkg);
								my $file = "$deps_dir/$pkg->{'filename'}";
								logger("Deleting file $file");
								unlink "$file" or error_handler('remove', "$file", "$!");
							}
						}
					}
				}
			}

			for my $pkg (values @$packages) {
				my $data = Util::fetch($pkg->{'filename'}, $pkg->{'url'});

				$pkg->verify($data) if $opt{'verify'};

				my $file = "$deps_dir/$pkg->{'filename'}";
				if (! -e $file) {
					Util::write_file($file, $data);
				}
				else {
					error_handler('download-file-exists', $file);
				}
			}

			if ($opt{'pack'}) {
				my $filename = "npm-deps.tar.gz";
				my @cmd = (
					'tar',
					'--auto-compress',
					'--mtime=@0',
					'--owner=0',
					'--group=0',
					'--numeric-owner',
					'--create',
					"--file=$filename",
					'-C',
					"$deps_dir",
					"\."
				);
				run3(\@cmd, \undef, \undef);
				error_handler('system-tar', join(' ', @cmd)) if $?;
			}
		}

		elsif ($act{'cacache'}) {
			my ($found, $not_found) = compare_dir_to_lockfile($deps_dir, @$packages);

			my $dir = Path->new("$cwd/_cacache");
			Path::make_path($dir);
			error_handler('dir-not-empty', $$dir) if !Util::is_empty_dir($$dir);

			my $cacache = Cacache->new($dir);
			$cacache->init();

			for my $pkg (values @$packages) {
				$cacache->put("make-fetch-happen:request-cache:$pkg->{'url'}", $pkg->{'url'}, "$deps_dir/$pkg->{'filename'}", $pkg->integrity());
			}
		}

		elsif ($act{'verify-files'}) {
			my ($found, $not_found) = compare_dir_to_lockfile($deps_dir, @$packages);

			my $bad;
			for my $pkg (values @$found) {
				my $data = Util::fetch($pkg->{'filename'});
				$pkg->verify($data) ? next : ($bad = 1);
			}

			$bad = 1 if scalar @$not_found;
			for my $pkg (values @$not_found) {
				error("File not found for $pkg->{'name'}");
			}

			show('Successfully verified all files') if !$bad;
		}
	}
}

sub fixup_lockfile {
	my ($decoded_lock) = JSON::PP::decode_json(@_);

	my $fixed;
	my $lock_ver = $decoded_lock->{'lockfileVersion'};
	if ($lock_ver =~ m/2|3/) {
		for my $pkg (values %{$decoded_lock->{'packages'}}) {
			# https://docs.npmjs.com/cli/configuring-npm/package-lock-json#packages
			my $uri = \URI->new($pkg->{'resolved'});
			if (defined $$uri->scheme) {
				if ($pkg->{'integrity'}) {
					if ($$uri->scheme =~ m/^(git|git\+ssh|git\+https|ssh)$/) {
						$fixed = 1;
						delete $pkg->{'integrity'};
					}
				}
			}
		}
	}
	else {
		error_handler('lock-version-unsupported', $lock_ver);
	}

	return $fixed ? \$decoded_lock : undef;
}

sub compare_dir_to_lockfile {
	# splits the list of @packages into @not_found (for downloading) and
	# @found (for verifying)
	# finally asks to delete 
	my ($dir, @packages) = @_;

	my (%pkg_files, %dir_files);
	%pkg_files = map {$_->{'filename'} => $_} @packages;
	find(sub {-f && ($dir_files{$_} = 1)}, $dir);

	# compare
	my (@found, @not_found);
	for my $file (keys %pkg_files) {
		if (exists $dir_files{$file}) {
			# found
			push(@found, $pkg_files{$file});
			delete $dir_files{$file};
		}
		else {
			# not found
			push(@not_found, $pkg_files{$file})
		}
	}

	# %dir_files now contains files not listed in the lockfile
	# ask to delete them
	if (keys %dir_files) {
		warning("Warning: files not referenced in package-lock.json found!");
		
		if (!$opt{'delete'}) {
			Util::prompt_yn("Do you want to continue") || error_handler('dont-continue');
		}

		delete_files(keys %dir_files);
	}

	return \@found, \@not_found;
}

sub delete_files {
	my (@files) = @_;

	my $delete_all = $opt{'delete'} ? 1 : 0;
	for my $file (@files) {
		my $file = "$deps_dir/$file";

		my $delete;
		if ($delete_all) {
			$delete = 1;
		}
		else {
			my $response = Util::prompt("Delete file \"$file\" ([Y]es/[A]ll - yes to all/[N]o)?: ", qw/yes y all a no n/);

			next if !$response || $response =~ m/(n|no)/;
			$delete = 1 if $response =~ m/(y|yes)/;
			($delete, $delete_all) = (1, 1) if $response =~ m/(a|all)/;
		}

		if ($delete) {
			show("Deleting file $file");
			unlink "$file" or error_handler('remove', "$file", "$!");
		}
	}
}

sub lockfile {
	my ($lockfile, $force_git_deps, $force_empty_cache) = @_;

	my @packages;
	for my $pkg (values @{get_packages($lockfile)}) {
		my $package = Package->from_lock($pkg);
		push(@packages, $package);
	}

	error_handler('no-deps') if (!@packages && !$force_empty_cache);

	my @new_packages;
	my @gits = grep {($_->{'specifics'}{'type'} eq 'git')} @packages;
	if (@gits) {
		for my $pkg (values @gits) {
			show("Recursively parsing lockfile for git sourced package \"$pkg->{'name'}\"...");

			my $path = $pkg->{'specifics'}{'workdir'};
			my $git_lockfile = Util::read_file_as("$path/package-lock.json", 'encoding(UTF-8)') if -e "$path/package-lock.json";
			my $package_json = JSON::PP::decode_json(Util::read_file_as("$path/package.json", 'encoding(UTF-8)'));
			my @scripts = keys %{$package_json->{'scripts'}};
			my @unsupported = qw/postinstall build preinstall install prepack prepare/;
			my %seen;
			$seen{$_}++ for @unsupported;
			for my $script (@scripts) {
				if ($seen{$script} && !$git_lockfile && !$force_git_deps) {
					error_handler('git-deps-lockfile', $_->{'name'});
				}
			}

			if ($git_lockfile) {
				push(@new_packages, lockfile($git_lockfile, $force_git_deps, 1));
			}
		}
	}

	@packages = (@packages, @new_packages);

	# dedup by url again
	my %seen;
	@packages = grep {!$seen{$_->{'url'}}++} @packages;

	return \@packages;
}

sub get_packages {
	my ($decoded_lock) = JSON::PP::decode_json(@_);

	my @packages;
	while (my ($pkg_name, $pkg) = each %{$decoded_lock->{'packages'}}) {
		# https://docs.npmjs.com/cli/configuring-npm/package-lock-json#packages
		my $uri = \URI->new($pkg->{'resolved'});
		if (defined $$uri->scheme && $pkg_name ne '') {
			$pkg->{'name'} = $pkg_name;
			$pkg->{'uri'} = $uri;
			push(@packages, $pkg);
		}
	}

	# dedup by url
	my %seen;
	@packages = grep {!$seen{$_->{'resolved'}}++} @packages;

	return \@packages;
}

sub get_hosted_git_url {
	my ($uri) = @_;

	if ($$uri->scheme =~ m/^(git|git\+ssh|git\+https|ssh)$/) {
		# https://metacpan.org/pod/URI#SCHEME-SPECIFIC-SUPPORT
		# uri's with unsupported schemes can only use common and generic methods
		my $authority = $$uri->authority;
		if ($authority =~ m/github.com$/) {
			my @segments = $$uri->path_segments;
			# https://metacpan.org/pod/URI#$uri-%3Epath_segments
			# shift the first path_segment
			shift @segments;

			my $user = shift @segments;
			my $project = shift @segments;
			my $type = shift @segments;
			my $commit = shift @segments;

			if (!defined $commit) {
				$commit = $$uri->fragment;
			}
			elsif (defined $type && $type ne 'tree') {
				return undef;
			}

			$project =~ s/\.git$// if $project =~ m/\.git$/;

			return (
				"https://codeload.github.com/$user/$project/tar.gz/$commit",
				"$project-$commit.tar.gz"
			);
		}
	}
	else {
		return undef;
	}
}

sub error_handler {
	my ($err,$one,$two) = @_;

	my $show_help;
	my ($exit, $errno) = (1, 0);
	my $message = do {
		if ($err eq 'empty'){ 'empty value' }
		# options
		elsif ($err eq 'unknown-option') {
			# GetOptions will print a warning for us
			$errno=1; $show_help = 1; undef }
		elsif ($err eq 'unknown-action') {
			$errno=2; $show_help = 1; "Unknown action: $one" }
		elsif ($err eq 'select-action') {
			$errno=3; $show_help = 1; "No action provided" }
		elsif ($err eq 'select-one-action') {
			$errno=4; $show_help = 1; "Select exactly one action from \"$one\"" }
		# package-lock.json rules
		elsif ($err eq 'no-integrity') {
			$errno = 10; "Registry package $one missing integrity string" }
		elsif ($err eq 'no-url') {
			$errno = 11; "Package $one missing url" }
		elsif ($err eq 'no-filename') {
			$errno = 12; "Couldn't parse a filename for package $one" }
		elsif ($err eq 'git-deps-lockfile') {
			$errno = 13; "Git dependency $one contains install scripts and no lockfile. This will probably break.\nIf you want to try to use this dependency, set forceGitDeps" }
		elsif ($err eq 'no-deps') {
			$errno = 14; "No cacheable dependencies were found. Please check package-lock.json and verify that it has \"resolved\" URLs \"integrity\" hashes.\nIf generating an empty cache is intentional, set forceEmptyCache." }
		elsif ($err eq 'lock-version-unsupported') {
			$errno = 15; "lockfileVersion $one is unsupported" }
		# file rules
		elsif ($err eq 'open') {
			$errno = 20; "Cannot open file $one \nError: $two" }
		elsif ($err eq 'create') {
			$errno = 21; "Cannot create file $one \nError: $two" }
		elsif ($err eq 'write') {
			$errno = 22; "Cannot write to file $one \nError: $two" }
		elsif ($err eq 'remove') {
			$errno = 23; "Cannot remove file $one \nError: $two" }
		elsif ($err eq 'mkdir') {
			$errno = 24; "Cannot create directory $one \nError: $two" }
		elsif ($err eq 'open-dir-failed') {
			$errno = 25; "Cannot open directory $one \nError: $two" }
		elsif ($err eq 'dir-not-empty') {
			$errno = 26; "$one directory is not empty" }
		elsif ($err eq 'symlink') {
			$errno = 27; "Cannot symlink file to $one \nError: $two" }
		# download rules
		elsif ($err eq 'download-error') {
			$errno = 30; "Error downloading file: $one \nError: $two" }
		elsif ($err eq 'not-download-action') {
			$errno = 31; "Cannot download missing files with this action"}
		elsif ($err eq 'download-file-exists') {
			$errno = 32; $exit = 0; "File $one already exists. Skipping" }
		# verify rules
		elsif ($err eq 'verify-mismatch') {
			$errno = 40; $exit = 0; "Mismatching integrity for package: $one \n$two" }
		elsif ($err eq 'invalid-algo') {
			$errno = 41; "Invalid hash algorithm: $one \nValid algorithms: $two" }
		elsif ($err eq 'system-tar') {
			$errno = 50; "System call to tar failed with arguments:\n$one" }
		# signals/user input
		elsif ($err eq 'caught-signal') {
			$errno = 60; "\nCaught signal. Cleaning up...\n$one" }
		elsif ($err eq 'dont-continue') {
			# the script should print a warning message with explanation before 
			# getting here. exit with 0 and no message
			$errno = 0; undef }
		else {
			$errno = 255; "Unhandled error: $err" }
	};
	error("$message") if defined $message;
	print "Check -h for correct parameters.\n" if $show_help;
	exit $errno if $exit;
}

sub show_options {
	Pod::Usage::pod2usage(1);
	exit(0);
}

sub show_version {
	use File::Basename;
	my $prog = basename($0);
	print(<<"__EOS__");
$prog version: v$VERSION
Using Perl version: $^V
__EOS__
   exit(0);
}

sub show {
	my ($str) = @_;

	print "$output_prefix $str\n";
}

# todo: log properly
# todo: maybe stats as well
sub logger {
	my ($str) = @_;

	print "$str\n" if $opt{'verbose'};
}

sub warning {
	my ($str) = @_;

	print "$warn_prefix $str\n";
}

sub error {
	my ($str) = @_;

	print "$err_prefix $str\n";
}

sub trap_cleanup {
	# simply calling exit here will delete tmpdirs as required
	# add other cleanup code here
	error_handler('caught-signal', $!)
}

{
package Package;

sub from_lock {
	my $class = shift;

	my ($pkg) = @_;

	my ($resolved, $uri) = ($pkg->{'resolved'}, $pkg->{'uri'});
	my ($hosted, $filename) = main::get_hosted_git_url($uri);
	my %specifics;

	if (!$hosted) {
		# filename must include the scope to avoid clobbering later
		# https://docs.npmjs.com/about-scopes
		my @segments = $$uri->path_segments;
		$filename = ($segments[1] =~ m/^@/) ? "$segments[1]_$segments[-1]" : "$segments[-1]";

		%specifics = (
			'type' => 'registry',
			'integrity' => $pkg->{'integrity'} || main::error_handler('no-integrity', $pkg->{'name'}),
		);
	}
	else {
		my $data = Util::fetch($filename, $hosted);

		my $workdir = File::Temp->newdir('packageXXXX', 'CLEANUP' => $opt{'cleanup'});

		my @cmd = (
			'tar',
			'--extract',
			'--gzip',
			'--strip-components=1',
			"--directory=$workdir"
		);
		main::run3(\@cmd, \$data, \undef);
		main::error_handler('system-tar', join(' ', @cmd)) if $?;

		$resolved = $hosted;
		%specifics = (
			'type' => 'git',
			'workdir' => $workdir,
		);
	}

	my $self = {
		'name' => $pkg->{'name'},
		'filename' => $filename || main::error_handler('no-filename', $pkg->{'name'}),
		'url' => $resolved || main::error_handler('no-url', $pkg->{'name'}),
		'specifics' => \%specifics,
	};

	return bless $self, $class;
}

sub verify {
	my $self = shift;

	my ($data) = @_;

	if ($self->{'specifics'}{'type'} eq 'registry') {
		my $integrity = $self->integrity();
		if ($integrity) {
			my ($algo, $int_hex) = Util::integrity_to_hex($integrity);
			my $file_hex = do {
				my $sha = Digest::SHA->new($algo);
				$sha->add($data);
				$sha->hexdigest;
			};
			if ($int_hex ne $file_hex) {
				main::error_handler('verify-mismatch', $self->{'name'}, "Integrity: $int_hex\nFile:      $file_hex");
				return 0;
			}
			main::logger("Successfully verified $self->{'url'}");
			return 1;
		}
		else {
			main::error_handler('no-integrity', $self->{'name'});
		}
	}
	elsif ($self->{'specifics'}{'type'} eq 'git') {
		# git packages don't have integrity strings
		# default to success
		return 1;
	}
}

sub integrity {
	my $self = shift;

	return $self->{'specifics'}{'integrity'} ? $self->{'specifics'}{'integrity'} : 0
}
}

{
package Cacache;

sub _push_hex_segments {
	my ($path, $hex) = @_;

	$path->push(substr($hex, 0, 2));
	$path->push(substr($hex, 2, 2));
	$path->push(substr($hex, 4));
}

sub new {
	my $class = shift;

	my ($path) = @_;

	return bless \$path, $class;
}

sub init {
	my $self = shift;

	Path::make_path($$self->join('content-v2'));
	Path::make_path($$self->join('index-v5'));
}

# symlinks tarballs into a cacache structure, then writes an index entry for them
sub put {
	my $self = shift;

	my ($key, $url, $file, $integrity) = @_;

	my ($algo, $hex, $filesize);

	if ($integrity) {
		($algo, $hex) = Util::integrity_to_hex($integrity);
	}
	else {
		$algo = 'sha512';

		my $sha = Digest::SHA->new($algo);
		$sha->addfile($file);
		# digest functions are read-once: https://perldoc.perl.org/Digest::SHA#digest
		my $b64_digest = $sha->clone->b64digest;
		while (length($b64_digest) % 4) {
			$b64_digest .= '=';
		}
		$hex = $sha->hexdigest;
		$integrity = "$algo" . '-' . "$b64_digest";
	}

	$filesize = -s $file;

	my $content_path = do {
		my $path = $$self->join('content-v2');
		$path->push($algo);
		_push_hex_segments($path, $hex);
		$path;
	};

	Path::make_path($content_path->parent());
	symlink($file, $$content_path) or main::error_handler('symlink', $content_path, $!);

	my $index_path = do {
		my $path = $$self->join('index-v5');
		_push_hex_segments($path, Digest::SHA::sha256_hex($key));
		$path;
	};

	Path::make_path($index_path->parent());

	my $json_data = JSON::PP::encode_json({
		'key' => $key,
		'integrity' => $integrity,
		'time' => 0,
		'size' => $filesize,
		'metadata' => {
			'url' => $url,
			'options' => {
				'compress' => JSON::PP::true
			}
		}
	});

	$json_data = Digest::SHA::sha1_hex($json_data) . "\t" . $json_data;
	Util::write_file($$index_path, $json_data);
}
}

{
package Path;

sub _cleanup_path_strings {
	my (@strings) = @_;

	map {s/^\/|\/$//g} @strings;
	return join('/', @strings);
}

sub new {
	my $class = shift;

	my ($path) = @_;

	$path =~ s/\/$//;

	return bless \$path, $class;
}

sub append {
	my $self = shift;

	my (@strings) = @_;

	my $strings = _cleanup_path_strings(@strings);
	$$self .= '/' . $strings;
}

sub prepend {
	my $self = shift;

	my (@strings) = @_;

	my $strings = _cleanup_path_strings(@strings);
	substr($$self, 0, 0, '/' . $strings);
}

sub push {
	my $self = shift;

	my ($string) = @_;

	$self->append($string);
}

sub join {
	my $old_self = shift;

	# accept multiple strings? why?
	my ($string) = @_;

	my $new_self = Path->new($$old_self);
	$new_self->append($string);

	return $new_self;
}

sub parent {
	my $old_self = shift;

	my $new_self = Path->new(File::Basename::dirname($$old_self));

	return $new_self;
}

sub make_path {
	my $self = shift;

	my $err;
	File::Path::make_path($$self, {'error' => \$err}) || make_path_error($err);
}

# https://perldoc.perl.org/File::Path#ERROR-HANDLING
sub make_path_error {
	my ($err) = @_;

	if ($err && @$err) {
		for my $diag (@$err) {
			my ($file, $message) = %$diag;
			if ($file eq '') {
				main::error_handler("General make_path() error \nError: $message");
			}
			else {
				main::error_handler('mkdir', $file, $message);
			}
		}
	}
}
}

{
package Util;

my %algos = ('sha1' => 1, 'sha512' => 1);

sub integrity_to_hex {
	my ($integrity) = @_;

	my ($algo, $b64_str) = split(/-/, $integrity, 2);
	if (exists $algos{$algo}) {
		my $hex = join('', (unpack("H*", MIME::Base64::decode_base64($b64_str))));
		return ($algo, $hex);
	}
	else {
		my $valid_algos = join(', ', keys %algos);
		main::error_handler('invalid-algo', $algo, $valid_algos);
	}
}

sub fetch {
	my ($filename, $url) = @_;

	if (! -e "$deps_dir/$filename" && $url) {
		main::error_handler('not-download-action') if !$act{'download'};

		main::logger("Downloading " . $url);
		my $ua = LWP::UserAgent->new();
		my $retries;
		{
			++$retries;
			my $response = $ua->get("$url");
			if ($response->is_success) {
				return $response->content;
			}
			else {
				sleep 2;
				redo if $retries < 3;
			}
			main::error_handler('download-error', $url, $response->status_line);
		}
	}
	else {
		return read_file_as("$deps_dir/$filename", 'raw');;
	}
}

sub read_file_as {
	my ($file, $encoding) = @_;

	my $data = do {
		open(my $fh, "<:$encoding", $file) or main::error_handler('open', $file, "$!");
		local $/; # slurp entire file
		<$fh>
	};
	return $data;
}

sub write_file {
	my ($file, $data) = @_;

	open(my $fh, '>:raw', "$file") or error_handler('open', "$file", "$!");
	print $fh $data;
	close $fh;
}

sub is_empty_dir {
	my ($dir) = @_;
	opendir(my $dh, $dir) or main::error_handler('open-dir-failed', $dir, "$!");
	my $count = scalar(grep {$_ ne '.' && $_ ne '..'} readdir($dh));
	closedir $dh;
	return $count == 0;
}

sub prompt {
	my ($query, @accepted) = @_;

	print "$query_prefix $query";

	my $response;
	while ($response = <STDIN>) {
		chomp $response;
		last if grep {$_ eq $response} @accepted;
		if ($response eq '') {
			$response = undef;
			last;
		}
		print "Invalid response \"$response\". Enter input again: ";
	}

	return $response;
}

sub prompt_yn {
	my ($query) = @_;

	my $response = prompt("$query (y/n)?: ", qw/yes y no n/);
	# assume 'enter' is 'no'
	$response = 0 if !$response || $response =~ m/(n|no)/;
	$response = 1 if $response =~ m/(y|yes)/;

	return $response;
}
}

{
package OptionsHandler;

sub get {
	my $count = 0;
	Getopt::Long::GetOptions(
	'pack' => sub {
		$opt{'pack'} = 1; },
	'lockfile=s' => \$opt{'lockfile'},
	'update' => sub {
		$opt{'update'} = 1; },
	'delete' => sub {
		$opt{'delete'} = 1; },
	'no-verify' => sub {
		$opt{'no-verify'} = 1; },
	'no-cleanup' => sub {
		$opt{'no-cleanup'} = 1; },
	'verbose' => sub {
		$opt{'verbose'} = 1; },
	'h|help' => sub {
		$opt{'help'} = 1; },
	'v|version' => sub {
		$opt{'version'} = 1; },
	'<>' => sub {
		my ($arg) = @_;

		if ($arg eq 'cacache') {
			$act{'cacache'} = 1; }
		elsif ($arg eq 'download') {
			$act{'download'} = 1; }
		elsif ($arg eq 'verify-files') {
			$act{'verify-files'} = 1; }
		elsif ($arg eq 'fixup-lockfile') {
			$act{'fixup-lockfile'} = 1; }
		else {
			main::error_handler('unknown-action', $arg); }
		}
	) or main::error_handler('unknown-option');

	post_process()
}

sub post_process {
	# run the functions that exit after completion first
	main::show_options() if $opt{'help'};
	main::show_version() if $opt{'version'};

	option_consistency_checks();

	$opt{'verify'} = $opt{'no-verify'} ? 0 : 1;
	$opt{'cleanup'} = $opt{'no-cleanup'} ? 0 : 1;
}

sub option_consistency_checks {
	my $acts = keys %act;
	if ($acts == 0) {
		main::error_handler('select-action');
	}
	elsif ($acts > 1) {
		main::error_handler('select-one-action', join(', ', keys %act))
	}
}
}

main()