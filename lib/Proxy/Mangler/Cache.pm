package Proxy::Mangler::Cache;

use warnings;
use strict;

use Digest::SHA1 qw(sha1_hex);
use Storable qw(nfreeze thaw);
use Symbol qw(gensym);
use IO::File;

# The cache is kept global so that simultaneous sessions may check it.
my %cache;
my %progress;

# -><- What happens with partial content?
# -><- Can we use ETag headers for anything fun?
#
#   HTTP/1.1 206 Partial Content
#   Cache-Control: max-age=3600
#   Connection: close
#   Date: Fri, 19 Mar 2004 15:54:47 GMT
#   Accept-Ranges: bytes
#   ETag: "113411e-27c07-40288682"
#   Server: Apache/1.3.29
#   Content-Length: 6567
#   Content-Range: bytes 156256-162822/162823
#   Content-Type: image/jpeg
#   Expires: Fri, 19 Mar 2004 16:54:47 GMT
#   Last-Modified: Tue, 10 Feb 2004 07:21:38 GMT

sub new {
	my ($class, %conf) = @_;

	my $self = bless \%conf, $class;
	return $self;
}

sub mangle {
	my ($self, $request) = @_;

	# If we have caching on, check for it in our cache directory.  This
	# is highly experimental---I mean, even moreso than the rest of the
	# proxy---and definitely does several Wrong Things with regards to
	# caching proxies.
	#
	# -><- We load and send the entire content of a cached object here.
	# A smarter thing to do would be to send it in chunks, and I imagine
	# I'll need to code for that in short order.

	# -><- Need to honor Expires header.
	# Expires: Thu, 04 Mar 2004 19:00:03 GMT

	# -><- Need to honor Cache-Control: max-age=SECONDS header.
	# Cache-Control: max-age=3600

	my $uri = $request->uri();
	my $uri_hash = sha1_hex("$uri");  # Ensure stringified URI object.

	my $cache_file;
	$cache_file = $self->{cache_dir} . "/$uri_hash" if $self->{cache_dir};

	# Bail out if we can't or shouldn't cache.
	unless ($self->can_cache($request)) {
		unlink $cache_file if $cache_file;
		return;
	}

	# If the cache record exists in memory, it's still being written to
	# by some session.  We avoid reading from it since its contents are
	# incomplete.

	return if exists $cache{$uri_hash};

	# Bail out if there's no cache file.
	return unless -f $cache_file;

	# Serve from the cache file, if it exists.
	# TODO - In the future, we should consider serving what we can from
	# the file, then "tailing" it to serve contents as they arrive.

	my $fh = IO::File->new();
	unless ($fh->open("<$cache_file")) {
		warn(
			"<C> Read error: $!\n",
			"<C>   uri : $uri\n",
			"<C>   file: $cache_file\n",
		);
		return;
	}

	warn "<C> Hit: Serving cached version of $uri\n";

	my $length = <$fh>;
	chomp $length;

	# TODO - If the length in the file doesn't match the current content
	# length, consider it a cache miss.

	my $raw_response = "";
	my $read_length = read($fh, $raw_response, $length);

	unless ($length == $read_length) {
		warn(
			"<C> Wanted to read $length bytes; only got $read_length.\n",
			"<C>   uri : $uri\n",
			"<C>   file: $cache_file\n",
		);
		return;
	}

	# TODO - What does this do?
	my $response = thaw($raw_response);
	my $read = sub {
		my $data;
		my $more = read($fh, $data, 65536);

		close $fh unless ($more);
		return $data;
	};

	return ($response, $read);
}


sub can_cache {
	my ($self, $req_or_resp) = @_;
	# Determine whether the page is cacheable, returning true or false.

	# -><- Check the Expires header, and don't save the page if it's
	# pre-expired.

	# Not cacheable if there's no cache directory configured.
	return unless $self->{cache_dir};

	# Not caching certain methods.
	return unless $req_or_resp->method() eq "GET";

	# Not caching URIs that include queries.
	my $uri   = $req_or_resp->uri();
	my $query = $uri->query();
	return if defined($query) and length($query);  #  TODO - Better idiom?

	# Not cacheable if Pragma: no-cache
	my $pragma = $req_or_resp->header("Pragma");
	return if defined $pragma and $pragma =~ /\bno-cache\b/i;

	# Not cacheable if Cache-Control: no-cache or private
	my $cache_control = $req_or_resp->header("Cache-Control");
	return if (
		defined $cache_control and
		$cache_control =~ /\b(no-cache|private)\b/i
	);

	# Certain types are not cacheable.
	my $type = $req_or_resp->content_type;
	return if $type =~ /\b(application|octet|stream)\b/i;

	# Cacheable if it gets this far.
	return 1;
}


sub unmangle {
	my ($self, $request, $response, $data) = @_;

	# We're amidst the processing of this response.
	if (defined $progress{"$response"}) {

		# We decided not to cache it.  Return quickly, possibly cleaning
		# up after ourselves if this was the end of the response data.
		if ($progress{"$response"} eq "no_caching") {
			unless (defined $data) {
				if ($self->can_cache($request)) {
					my $request_uri = $request->uri();
					my $uri_hash = sha1_hex("$request_uri");  # Ensure stringified URI.
					delete $cache{$uri_hash} if defined $uri_hash;
					delete $progress{"$response"};
				}
			}
			return;
		}

		# Continue processing the response.
		my ($handle, $uri_hash) = @{$progress{"$response"}};
		if (defined $data) {
			print $handle $data;
			return;
		}

		close $handle;
		delete $cache{$uri_hash};
		delete $progress{"$response"};
		return;
	}

	# See if we can cache.
	my $uri = $request->uri();
	my $uri_hash = sha1_hex("$uri");  # Ensure stringified URI object.

	my $cache_file;
	$cache_file = $self->{cache_dir} . "/$uri_hash" if $self->{cache_dir};

	unless ($self->can_cache($request)) {
		unlink $cache_file if $cache_file;
		return;
	}

	# we can cache, but don't neccesarily are going to
	$progress{"$response"} = "no_caching";

	# It's already cached.
	# TODO - Do we check for time-based headers here?
	return if -f $cache_file;

	my $handle = gensym();
	unless (open($handle, ">$cache_file")) {
		my $uri = $request->uri();  # TODO - Return it from can_cache()?
		warn(
			"<C> Write error: $!\n",
			"<C>   uri : $uri\n",
			"<C>   file: $cache_file\n",
		);
		return;
	}

	binmode($handle);
	# ok, we're going to do caching
	$progress{"$response"} = [$handle, $uri_hash];
	$cache{$uri_hash} = 1;

	my $frozen_response = nfreeze($response);
	print $handle length($frozen_response), "\n", $frozen_response;
	print $handle $data if $data;

	return;
}

1;
