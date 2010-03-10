# $Id$

package Proxy::Util;

use warnings;
use strict;

use base qw(Exporter);

our @EXPORT_OK = qw(
	generate_host_regexp
	generate_pq_regexp
	generate_mach_regexp
	check_blocked
);

our %EXPORT_TAGS = (all => \@EXPORT_OK);

###############################################################################
# Helper functions.  These are NOT POE EVENT HANDLERS.

# Generate a regular expression from a list of constant strings.
# TODO Rocco has a way to make optimal regexps from strings.
sub generate_host_regexp {
	return undef unless @_;
	my $regexp = (
		"\.?(?:" .
		join( "|", map { quotemeta } sort { length($b) <=> length($a) } @_ ) .
		")\$"
	);
	return qr/$regexp/i;
}

# Combine several regular expressions into one, by combining them with
# an alternation.
sub generate_pq_regexp {
	return undef unless @_;
	my $regexp = (
		"(?:" .
		join( "|", sort { length($b) <=> length($a) } @_ ) .
		")"
	);
	return qr/$regexp/i;
}

# Combine several regular expressions into one, by combining them with
# an alternation.  This regexp is anchored at the beginning of the
# string.
sub generate_mach_regexp {
	return undef unless @_;
	my $regexp = (
		"^(?:" .
		join( "|", sort { length($b) <=> length($a) } @_ ) .
		")"
	);
	return qr/$regexp/i;
}

# Returns undef if $uri is not blocked.  Returns a reason explaining
# why it's blocked if it is.
sub check_blocked {
	my ($uri, $proxy_conf) = @_;

	my $blocked;
	if (
		defined($proxy_conf->{host_regexp})
		and $uri->host() =~ $proxy_conf->{host_regexp}
	) {
		$blocked = "host";
	}
	elsif (
		defined($proxy_conf->{mach_regexp})
		and $uri->host() =~ $proxy_conf->{mach_regexp}
	) {
		$blocked = "machine";
	}
	elsif (
		defined($proxy_conf->{pq_regexp})
		and $uri->path_query() =~ $proxy_conf->{pq_regexp}
	) {
		$blocked = "path/query";
	}

	if ($blocked) {
		return "blocked post by $blocked: $uri\n";
	} else {
		return undef;
	}
}

1;
