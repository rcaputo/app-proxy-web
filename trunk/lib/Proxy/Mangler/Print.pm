# $Id$

package Proxy::Mangler::Print;

use warnings;
use strict;

my %requests;

sub new {
  my ($class, %conf) = @_;

  my $self = bless \%conf, $class;
  return $self;
}

sub mangle {
  my ($self, $request) = @_;
  # rewrite url
  # save a copy of the original, so we can sneak it back before
  # we hand it to our Proximity::Reporter(s)
  my $uri = $request->uri;
  my $copy = $request->clone;
  $requests{$request} = $copy;
  my $host = $uri->host;
  my $path = $uri->path;
  #print "rewriting for $host\n";
  if ($host =~ /(?:perl|oreillynet|xml|onjava)\.com$/) {
    $path =~ s|^/pub|/lpt|;
    $path .= "index.html" if ($path =~ m|/$|);
    $uri->path ($path);
    $request->uri ($uri);
  } elsif ($host =~ /computerworld\.com$/) {
    my $new_uri = 'http://www.computerworld.com/printthis/2003/0,4814,';
    if ($path =~ m|/story/0,\d+,(\d+),\d+.html$|) {
      $new_uri .= "$1,00.html";
    } else {
      $new_uri = $uri;
    }
    $uri = URI->new ($new_uri);
    $request->uri ($uri);
  } elsif ($host =~ /zdnet\.com$/) {
    my $new_uri = 'http://www.zdnet.com/filters/printerfriendly/0,6061,';
    if ($path =~ m|^/techupdate.*/0,\d+,(\d+),\d+.html$|) {
      $new_uri .= "$1-92,00.html";
    } elsif ($path =~ m|/reviews/0,\d+,(\d+),\d+.html$|) {
      $new_uri .= "$1-3,00.html";
    } else {
      $new_uri = $uri;
    }
    $uri = URI->new ($new_uri);
    $request->uri ($uri);
  } elsif ($host =~ /(?:zdnet|news).com.com$/) {
    if ($uri->path =~ /(2100|2010|2009)-[\d_]+-\d+\.html$/) {
      $request->referer ("$uri");
      my $new_uri = "$uri";
      $new_uri =~ s/$1/2102/;
      $request->uri ($new_uri);
    }
  } elsif ($host =~ /guardian\.co\.uk$/) {
    if ($uri->path =~ /2100-[\d_]+-\d+\.html$/) {
      $request->referer ("$uri");
      my $new_uri = "$uri";
      $new_uri =~ s/2100/2102/;
      $request->uri ($new_uri);
    }
#
#  } elsif ($host =~ /www.cnn.com$/) {
#    my $path = $uri->path;
#    print "\tpath is $path\n";
#    print "time is ", time, "last requested at ", $foo{$uri}, "\n";
#    unless ($foo{$uri} && $foo{$uri} + 10 > time) {
#      if ($uri->path =~ m|^/\d{4}(?:/\w+)+/\d{2}/\d{2}|) {
#	my $new_uri = "http://www.printthis.clickability.com/pt/printThis?clickMap=printThis&url=" . uri_escape($uri, "^A-Za-z0-9\-_.!~*\'()/");
#	print "DONE, uri is now $new_uri\n";
#	$request->uri ($new_uri);
#	$foo{$uri} = time;
#      }
#    }

  } elsif ($host =~ /(linuxjournal|newsforge).com$/) {
    $path =~ s/article\.(pl|php)/print.$1/;
    $uri->path ($path);
    $request->uri ($uri);
  } elsif ($host =~ /vnunet\.com$/) {
    $path =~ s/News/Print/;
    $uri->path ($path);
    $request->uri ($uri);
  } elsif ($host =~ /osnews\.com$/) {
    $path =~ s/story/printer/;
    $request->referer ($uri);
    $uri->path ($path);
    $request->uri ($uri);
  } elsif ($host =~ /devx\.com$/) {
    if ($path =~ m|Article/\d+$|) {
      $uri->path ("$path/1954");
      $request->uri ($uri);
    }
  } elsif ($host =~ /wired\.com$/) {
    #print "PATH $path\n";
    if ($path =~ m|archive/\d{2}.\d{2}/\w+\.html$|) {
      $path =~ s/\.html$/_pr.html/;
      $uri->path ($path);
      #print "PATH $path\n";
      $request->uri ($uri);
    }
  } elsif ($host =~ /internetweek\.com$/) {
    if ($path =~ m|showArticle.jhtml$|) {
      $path =~ s/showArticle/printArticle/;
    }
    $uri->path ($path);
    $request->uri ($uri);
  } elsif ($host =~ /geocrawler\.com$/) {
    $path =~ s/msg\.php3$/msg_raw.php3/;
    $uri->path ($path);
    $request->uri ($uri);
  }

  return;
}

sub unmangle {
  my ($self, $request, $response, $data) = @_;

  if (defined $requests{$request}) {
    $response->request (delete $requests{$request});
  }
  return;
}

1;
