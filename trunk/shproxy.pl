#!/usr/bin/perl

use warnings;
use strict;

use lib qw( ./lib );

#poe
use POE;
use POE::Component::Server::TCP;
use POE::Component::Client::HTTP;
use POE::Component::Client::DNS; # you want this for performance
use POE::Filter::HTTPD;
use POE::Filter::Stream;

#other stuff
use URI::Escape;
use HTTP::Response;

# local modules
use Proxy::Conf qw( SCALAR LIST REQUIRED );
use Proxy::Util qw(:all);
use Proxy::Mangler::Cache;
use Proxy::Mangler::Print;

sub TEXT_ONLY  () { 1 }  # Only report text/* things.
sub TRACE_HTTP () { 0 }  # Trace HTTP request/response headers.

# Define the format of our configuration file.
Proxy::Conf->associate_type_with_schema(
	proxy => {
		proxy => {
			ListenPort    => SCALAR | REQUIRED,
			block_host    => LIST,
			block_pq      => LIST,
			block_machine => LIST,
			noproxy_host  => LIST,
			cache_dir     => SCALAR,
		},
		bot => {
			Nick          => SCALAR | REQUIRED,
			Server        => LIST   | REQUIRED,
			Username      => SCALAR | REQUIRED,
			Ircname       => SCALAR,
			Channel       => SCALAR | REQUIRED,
			block_host    => LIST,
			block_machine => LIST,
			block_pq      => LIST,
		},
	},
);

my @manglers;
my %proxy;

sub CONF_PATH () { "./proxy.conf" }

my $config = Proxy::Conf->read(CONF_PATH, "proxy");
my $conf_mod_time = $^T + -M CONF_PATH;

my $blocked_image = pack(
	"H*",
	"4749463839610a000a00a10000000000ffffff00000000000021f904010a0002" .
	"002c000000000a000a00000219841d99a07cc10484c235880e527c696c2d9425" .
	"39d9c5694001003b"
);

### Spawn a web client to fetch requests through.

POE::Component::Client::HTTP->spawn( Alias => 'ua', Streaming => 32768 );

### Spawn proxy servers.

# Scan the configuration for "proxy" sections.  Spawn a proxy for each
# one.

my @proxies = $config->get_names_by_type("proxy");
foreach my $proxy_name (@proxies) {
	my %proxy_conf = $config->get_items_by_name($proxy_name);

	warn(
		"<P> Starting web proxy '$proxy_name' on port $proxy_conf{ListenPort}.\n"
	);

	POE::Component::Server::TCP->new(
		Alias        => "$proxy_name",
		Port         => $proxy_conf{ListenPort},
		ClientFilter => 'POE::Filter::HTTPD',
		Args         => [ $proxy_name ],

		ClientConnected => \&handle_http_connect,
		ClientInput     => \&handle_http_request,
		InlineStates    => { got_response => \&handle_http_response, },
	);

	# XXX - regenerate_manglers() resets @manglers for each proxy we're
	# running.  Not that we've ever run more than one in practice.
	# Anyway, if someone does try multiple proxies, they may be in for a
	# rude shock.  So: Is this intentional?
	regenerate_manglers(%proxy_conf);
	regenerate_proxy_conf($proxy_name, %proxy_conf);
}

### Run the proxy until it is done, then exit.

warn "<P> Entering main loop.\n";
POE::Kernel->run();
exit 0;

###############################################################################
# Handle HTTP proxy events.

# An HTTP client has connected. Let the session handling it know
# its name, so it can get at its config.
sub handle_http_connect {
	my ($heap, $name) = @_[HEAP, ARG0];

	$heap->{'name'} = $name;

	# Reload the configuration file if its modification time has
	# changed.

	# TODO - Is there any feasable way to check for #include files
	# changing?  Perhaps move the changed test into Conf.pm, and record
	# all the included files in the configuration object.  Then we can
	# say:  if ($config->has_changed()) { ... }

	# -><- Everything that gets a configuration should probably have a
	# reload, rehash, or regenerate method/event.  That would totally
	# revamp, rejuvinate, or retrofit the object after a configuration
	# file is reloaded.

	my $new_conf_time = $^T + -M CONF_PATH;
	unless ($new_conf_time == $conf_mod_time) {
		warn "<P> Reloading configuration.\n";
		$config = Proxy::Conf->read(CONF_PATH, "proxy");
		$conf_mod_time = $new_conf_time;

		regenerate_stuff($config);
	}
}

# The following group of functions (/^regenerate_/) regenerate various
# internal structures after a configuration file has been loaded (or
# reloaded).
#
# -><- They do not stop/restart the proxies yet, change proxy bind
# addresses or ports, or stuff like that.
#
# -><- Rocco thinks a rethink/refactor of the data structures is
# necessary.  Meanwhile, he's patching around the existing ones.

sub regenerate_stuff {
	my $config = shift;

	my @proxies = $config->get_names_by_type("proxy");
	foreach my $proxy_name (@proxies) {
		my %proxy_conf = $config->get_items_by_name($proxy_name);

		regenerate_manglers(%proxy_conf);
		regenerate_proxy_conf($proxy_name, %proxy_conf);
	}
}

sub regenerate_manglers {
	my %proxy_conf = @_;
	@manglers = (
		Proxy::Mangler::Print->new(%proxy_conf),
		Proxy::Mangler::Cache->new(%proxy_conf),
	);
}

sub regenerate_proxy_conf {
	my ($proxy_name, %proxy_conf) = @_;

	$proxy{$proxy_name} = {
		cache_dir   => $proxy_conf{cache_dir},
		host_regexp => generate_host_regexp(@{$proxy_conf{block_host}}),
		pq_regexp   => generate_pq_regexp(@{$proxy_conf{block_pq}}),
		mach_regexp => generate_mach_regexp(@{$proxy_conf{block_machine}}),
		conf        => \%proxy_conf,
	};
}

### Handle HTTP requests from the client.  Pass them to the HTTP
### client component for further processing.  Optionally dump the
### request as text to STDOUT.

# Received an HTTP::Request from the client.  Check wether the request
# is blocked; if not, pass it on to PoCo::Client::HTTP for fetching.
sub handle_http_request {
	my ( $kernel, $heap, $request ) = @_[ KERNEL, HEAP, ARG0 ];
	my $name = $heap->{'name'};
	my $pconf = $proxy{$name};

	# If the request is really a HTTP::Response, then it indicates a
	# problem parsing the client's request.  Send the response back so
	# the client knows what's happened.
	if ( $request->isa("HTTP::Response") ) {
		$heap->{client}->put($request);
		$kernel->yield("shutdown");
		return;
	}

	if (TRACE_HTTP) {
		print(
			">>>>>>>>>>>>>>>>>>>>\n",
			$request->as_string(),
			">>>>>>>>>>>>>>>>>>>>\n",
		);
	}

	my $uri = $request->uri();

	warn "<P> Request: $uri\n";

	# It's only an URI::_server for stuff that starts with http:// or
	# ftp://, etc. everything else is probably going to be a local
	# request
	unless ($uri->isa ('URI::_server')) {
		my $response;
		# since the only local thing we know how to handle is
		# the proxy autoconfiguration file, we return a 404 for
		# everything else, just in case.
		if ($request->uri eq '/conf.pac') {
			$response = HTTP::Response->new(200);
			$response->content_type("application/x-ns-proxy-autoconfig");
			$response->content(create_pac($pconf->{conf}));
		}
		elsif ($request->uri =~ m|^/bookmark/|) {
			if ($request->method eq 'POST') {
				my %query = $request->url->query_form;
				my $path = $request->url->path;
				$path =~ s|^/bookmark/||;
				$path = uri_unescape ($path);

				$response = HTTP::Response->new (204); #RC_NO_CONTENT
				$response->request ($request);
			}
		}
		$response = HTTP::Response->new(404) unless (defined $response);
		$heap->{client}->put($response);
		$kernel->yield("shutdown");
		return;
	}

	# Blocked request?
	my $blocked = check_blocked($uri, $pconf);
	if (defined $blocked) {
		warn "<P> Load $blocked";
		my $response;

		# Images blocked differently.
		if ($uri->path() =~ /\.(gif|jpe?g|tiff?|png)$/i) {
			$response = HTTP::Response->new(200);
			$response->content_type("image/gif");
			$response->content($blocked_image);
		}
		else {
			$response = HTTP::Response->new(403);
			$response->content_type("text/plain");
			$response->content("Blocked by a shadow proxy $blocked rule.");
		}
		$heap->{client}->put($response);
		$kernel->yield("shutdown");
		return;
	}

	foreach my $mangler (@manglers) {
		my ($response, $data_handler) = $mangler->mangle($request);
		if (defined $response) {
			$heap->{client}->put($response);
			$heap->{client}->set_output_filter(POE::Filter::Stream->new());

			while (my $data = &$data_handler) {
				$heap->{client}->put($data);
			}
			$kernel->yield("shutdown");
			return;
		}
	}

	# Rewrite and/or remove some headers to disable keep-alives.
	# POE's HTTP components don't support it yet.
	$request->header("Connection", "close");
	$request->header("Proxy-Connection", "close");
	$request->remove_header("Keep-Alive");

	warn "<P> Fetching: ", $request->uri, "\n";
	$kernel->post( "ua" => "request", "got_response", $request );
}

# Received an HTTP::Response from PoCo::Client::HTTP.  Ferry the
# response to the client so they can see it.
sub handle_http_response {
	my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
	my $name = $heap->{'name'};

	my $request = $_[ARG0]->[0];
	my ( $response, $data ) = @{$_[ARG1]};

	foreach my $mangler (reverse @manglers) {
		$mangler->unmangle ($request, $response, $data);
	}

	# Client has gone away?  Don't bother.  -><- Actually, we should
	# shut down the corresponding HTTP request, but PoCo::Client::HTTP
	# doesn't support it yet.  Someone should bug the author about that.
	return unless defined $heap->{client};

	# This is the first chunk of content to come back from a request.
	unless ($heap->{sent_headers}) {

		# Flag that the headers were sent.
		$heap->{sent_headers} = 1;

		if (TRACE_HTTP) {
			print(
				"<<<<<<<<<<<<<<<<<<<<\n",
				$response->as_string(),
				"<<<<<<<<<<<<<<<<<<<<\n",
			);
		}

		# Send the headers to the client.  Switch to stream mode so
		# content passes through the proxy unchanged.
		$heap->{client}->put($response);
		$heap->{client}->set_output_filter(POE::Filter::Stream->new());
	}

	# Send content, if we have it.  The client connection should
	# always be in stream mode by this point.
	if (defined $data) {
		$heap->{client}->put($data);
		return;
	}

	$kernel->yield("shutdown");
}

###############################################################################
# Helper functions.  These are NOT POE EVENT HANDLERS.

sub create_pac {
	my ($heap) = @_;

	warn "<P> Serving proxy autoconfig.\n";
	my $port = $heap->{ListenPort};

	my $file = <<EOF;
// generated by shproxy.
function FindProxyForURL(url, host)
{
		// only do http proxying
		if (url.substring(0, 5) != "http:") {
			return "DIRECT";
		// don't proxy not fully qualified hosts (i.e. local)
		} else if (isPlainHostName(host)) {
			return "DIRECT";
		// nor stuff on our class C subnet
		} else if (isInNet(host, myIpAddress(), "255.255.255.0")) {
			return "DIRECT";
		// rules for block_host and block_machine lines in proxy.conf
EOF

	foreach my $host (@{$heap->{noproxy_host}}) {
		$file .= <<EOL;
		} else if (shExpMatch(host, "*$host")) {
			return "DIRECT";
EOL
	}

	$file .=<<EOF;
		// if it is none of the above, proxy away
		} else {
				return "PROXY localhost:$port";
		}
}
EOF

	return $file;
}
