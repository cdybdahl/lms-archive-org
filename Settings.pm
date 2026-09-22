package Plugins::ArchiveLMA::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('plugin.archivelma');

# Real archive.org identifiers are always this shape. Rejecting anything
# else here means a mistyped or malicious value can never reach the Solr
# query string _baseQuery() builds.
use constant VALID_IDENTIFIER => qr/^[A-Za-z0-9_.-]+$/;

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ARCHIVELMA');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/ArchiveLMA/settings/basic.html');
}

# The collection list is managed by hand below rather than through the
# generic pref_* auto-save mechanism, since it's a variable-length list
# rather than a single value. indexRebuildHour is a plain scalar, so it
# uses the generic mechanism (the "pref_indexRebuildHour" field in
# basic.html) rather than needing its own hand-rolled handling.
sub prefs {
	return ($prefs, qw(indexRebuildHour));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	my $oldRebuildHour = $prefs->get('indexRebuildHour');
	my $collectionsChanged = 0;

	if ($params->{saveSettings}) {
		my $collections = $prefs->get('collections') || [];
		my @before = @$collections;

		my @delete = @{ ref $params->{delete} eq 'ARRAY' ? $params->{delete} : [ $params->{delete} ] };
		if (@delete) {
			my %delete = map { $_ => 1 } grep { defined } @delete;
			@$collections = grep { !$delete{$_} } @$collections;
		}

		for my $candidate ($params->{newcollection}, $params->{addcollection}) {
			next unless defined $candidate;

			my $new = $candidate;
			$new =~ s/^\s+|\s+$//g;
			next unless length($new);

			if ($new !~ VALID_IDENTIFIER) {
				$params->{warning} .= sprintf(string('PLUGIN_ARCHIVELMA_INVALID_COLLECTION'), $new);
			}
			elsif (!grep { $_ eq $new } @$collections) {
				push @$collections, $new;
			}
		}

		$prefs->set('collections', $collections);

		if (join("\x00", sort @before) ne join("\x00", sort @$collections)) {
			$collectionsChanged = 1;
			Plugins::ArchiveLMA::Plugin::rebuildValueIndexSoon();
		}
	}

	$params->{prefs}->{collections} = $prefs->get('collections') || [];

	$params->{hourOptions} = [ map {
		my $h = $_;
		{ value => $h, label => sprintf('%d:00 %s', ($h % 12 == 0 ? 12 : $h % 12), $h < 12 ? 'AM' : 'PM') };
	} 0..23 ];

	my $query = $params->{q};
	$query = '' unless defined $query;
	$query =~ s/^\s+|\s+$//g;
	$params->{discoverQuery} = $query;

	my %added = map { $_ => 1 } @{ $params->{prefs}->{collections} };

	Plugins::ArchiveLMA::Plugin::discoverCollections($query, sub {
		my $discovered = shift;

		if ($discovered) {
			$params->{discoverResults} = [ map {
				{ %$_, added => $added{ $_->{identifier} } ? 1 : 0 };
			} @{ $discovered->{results} } ];

			$params->{discoverCountText} = sprintf(string('PLUGIN_ARCHIVELMA_DISCOVER_COUNT'),
				scalar(@{ $discovered->{results} }), $discovered->{total});
		}
		else {
			$params->{discoverError} = 1;
		}

		my $body = $class->SUPER::handler($client, $params);

		if (!$collectionsChanged && $params->{saveSettings} && defined $params->{pref_indexRebuildHour}
			&& $params->{pref_indexRebuildHour} != ($oldRebuildHour // -1))
		{
			# Only reschedule for the new hour here if rebuildValueIndexSoon()
			# above didn't already arm a sooner one-off rebuild - otherwise
			# this would overwrite that with a possibly much-later time.
			Plugins::ArchiveLMA::Plugin::rescheduleIndexPrewarm();
		}

		$callback->($client, $params, $body, @args);
	});
}

1;
