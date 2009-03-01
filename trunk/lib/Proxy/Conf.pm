# $Id$

# Configuration reading and holding.  This is second-system in full
# effect.
#
# TODO Allow configuration files to be rewritten.

package Proxy::Conf;

use warnings;
use strict;
use Exporter;
use Carp qw(croak);

use vars qw(@ISA @EXPORT_OK);
@ISA       = qw(Exporter);
@EXPORT_OK = qw( SCALAR LIST REQUIRED );

sub SCALAR   () { 0x01 }
sub LIST     () { 0x02 }
sub REQUIRED () { 0x04 }

### The configuration is kept globally so anything can query it by
### name.  Rocco thinks this is a feature, but he's not quite sure.

my %schema;  # $schema{$conf_type} = $syntax
my %config;  # $config{$path}{$section}{$item_key} = $item_val

# Associate a file type with its definition.
sub associate_type_with_schema {
	my ($class, $type, $schema) = @_;
	$schema{$type} = $schema;
	foreach my $section (keys %{$schema{$type}}) {
		$schema{$type}{$section}{name} = SCALAR | REQUIRED;
	}
}

# Read a file of a given type.
sub read {
	my ($class, $path, $type) = @_;

	my $self = bless \$path, $class;

	# %config's primary key is, handily enough, the path where
	# configuration is loaded.  To support reloading, let's just blow
	# away any existing configuration at the given path.

	delete $config{$path};

	my ($section, %item, $section_line);

	croak "'$type' isn't a known configuration file type"
		unless exists $schema{$type};
	croak "'$path' doesn't exist" unless -e $path;
	croak "'$path' isn't a plain file" unless -f $path;

	my $schema = $schema{$type};

	open(CFG, "<$path") or croak "couldn't open '$path': $!";
	while (<CFG>) {
		chomp;
		s/^\s*\#.*$//;   # TODO Preserve comments for rewriting.
		next if /^\s*$/;

		# Section item.
		if (/^\s+(\S+)\s+(.*?)\s*$/) {

			die "item outside a section at $path line $.\n" unless defined $section;
			die "unknown item '$1' in section '$section' at $path line $.\n"
				unless exists $schema->{$section}->{$1};

			if ($schema->{$section}->{$1} & LIST) {
				push @{$item{$1}}, $2;
			}
			elsif (exists $item{$1}) {
				die "option $1 redefined at $path line $.\n";
			}
			else {
				$item{$1} = $2;
			}
			next;
		}

		# Section type.
		if (/^(\S+)\s*$/) {

			# A new section ends the previous one.
			$self->_flush_section($schema, $section, $section_line, \%item);

			$section      = $1;
			$section_line = $.;
			undef %item;

			# Pre-initialize any lists in the schema.
			while (my ($item_name, $item_flags) = each %{$schema->{$section}}) {
				if ($item_flags & LIST) {
					$item{$item_name} = [];
				}
			}

			next;
		}

		die "syntax error in $path at line $.\n";
	}

	$self->_flush_section($schema, $section, $section_line, \%item);

	return $self;
}

# Internal helper to perform post-section processing.
sub _flush_section {
	my ($self, $schema, $section, $section_line, $item) = @_;

	if (defined $section) {

		foreach my $item_name (sort keys %{$schema->{$section}}) {
			my $item_type = $schema->{$section}->{$item_name};

			if ($item_type & REQUIRED) {
				die "$section section needs a(n) $item_name item at $section_line\n"
					unless exists $item->{$item_name};
			}
		}

		die "$section section $item->{name} is redefined at $section_line\n"
			if exists $config{$$self}->{$item->{name}};

		my $name = $item->{name};
		$config{$$self}->{$name} = { %$item, _type => $section };
	}
}

# Fetch all the section names for a given section type.  There may be
# multiple sections of each type, each with a unique name.
sub get_names_by_type {
	my ($self, $type) = @_;
	my @names;

	while (my ($name, $item) = each %{$config{$$self}}) {
		next unless $item->{_type} eq $type;
		push @names, $name;
	}

	return @names;
}

# Fetch all the items for a section of a given name.
sub get_items_by_name {
	my ($self, $name) = @_;

	return () unless exists $config{$$self}{$name};
	return %{$config{$$self}{$name}};
}

1;
