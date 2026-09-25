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

# The collection list, and the per-collection gain map alongside it, are
# managed by hand below rather than through the generic pref_* auto-save
# mechanism, since both are variable-length/keyed rather than a single
# value. indexRebuildHour, rebuildIndexOnRestart, gainCompensationEnabled
# and streamingQuality are plain scalars, so they use the generic mechanism
# (the matching "pref_*" fields in basic.html) rather than needing their own
# hand-rolled handling.
sub prefs {
	return ($prefs, qw(indexRebuildHour rebuildIndexOnRestart gainCompensationEnabled streamingQuality));
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
		elsif ($params->{rebuildIndexNow}) {
			Plugins::ArchiveLMA::Plugin::rebuildValueIndexSoon();
			$params->{indexRebuildTriggered} = 1;
		}

		# One "gain_<identifier>" field per row currently shown in the
		# collections table (see basic.html); only non-zero, numeric values
		# are kept; a blank/zero field just means no per-collection gain
		# applies for that collection. An unparseable field keeps whatever
		# was already saved rather than silently dropping it, since this is
		# a plain text input and a bad submission (typo, stray paste) is no
		# reason to lose a value the user set correctly last time.
		my $existingGains = $prefs->get('collectionGains') || {};
		my %gains;
		for my $id (@$collections) {
			my $raw = $params->{"gain_$id"};
			next unless defined $raw;
			$raw =~ s/^\s+|\s+$//g;
			next unless length $raw;

			my $normalized = $raw;
			# A lone comma decimal separator (e.g. "-3,5") is accepted too -
			# non-US locales commonly type it that way out of habit, and this
			# is a plain text field so the browser never normalizes it.
			$normalized =~ s/,/./ if ($normalized =~ tr/,//) == 1 && $normalized !~ /\./;

			if ($normalized !~ /^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$/) {
				$params->{warning} .= sprintf(string('PLUGIN_ARCHIVELMA_INVALID_GAIN'), $raw, $id);
				$gains{$id} = $existingGains->{$id} if defined $existingGains->{$id};
				next;
			}

			$gains{$id} = $normalized + 0 if $normalized + 0 != 0;
		}
		$prefs->set('collectionGains', \%gains);
	}

	$params->{prefs}->{collections} = $prefs->get('collections') || [];
	$params->{prefs}->{collectionGains} = $prefs->get('collectionGains') || {};

	$params->{hourOptions} = [ map {
		my $h = $_;
		{ value => $h, label => sprintf('%d:00 %s', ($h % 12 == 0 ? 12 : $h % 12), $h < 12 ? 'AM' : 'PM') };
	} 0..23 ];

	my $query = $params->{q};
	$query = '' unless defined $query;
	$query =~ s/^\s+|\s+$//g;
	$params->{discoverQuery} = $query;

	my $sortKey = $params->{sort};

	# Explicit Previous/Next navigation always wins. Otherwise, adding a
	# collection stays on whatever page it was clicked from (discoverCurrentPage,
	# a hidden field carrying the page that was rendered); any other submission
	# (a new search, a sort change, saving the collection list, ...) resets to
	# page 1, since the underlying result set may well be different now.
	my $page;
	if (defined $params->{discoverGoto} && $params->{discoverGoto} =~ /^\d+$/ && $params->{discoverGoto} >= 1) {
		$page = $params->{discoverGoto};
	}
	elsif (defined $params->{addcollection} && defined $params->{discoverCurrentPage}
		&& $params->{discoverCurrentPage} =~ /^\d+$/)
	{
		$page = $params->{discoverCurrentPage};
	}
	else {
		$page = 1;
	}

	my %added = map { $_ => 1 } @{ $params->{prefs}->{collections} };

	Plugins::ArchiveLMA::Plugin::discoverCollections($query, $sortKey, $page, sub {
		my $discovered = shift;

		if ($discovered) {
			$params->{discoverResults} = [ map {
				{ %$_, added => $added{ $_->{identifier} } ? 1 : 0 };
			} @{ $discovered->{results} } ];

			$params->{discoverCountText} = sprintf(string('PLUGIN_ARCHIVELMA_DISCOVER_COUNT'),
				scalar(@{ $discovered->{results} }), $discovered->{total});

			$params->{discoverSort}    = $discovered->{sortKey};
			$params->{discoverPage}    = $discovered->{page};
			$params->{discoverHasPrev} = $discovered->{page} > 1 ? 1 : 0;
			$params->{discoverHasNext} = ($discovered->{page} * Plugins::ArchiveLMA::Plugin::DISCOVER_ROWS()) < $discovered->{total} ? 1 : 0;
			$params->{discoverPageText} = sprintf(string('PLUGIN_ARCHIVELMA_DISCOVER_PAGE'), $discovered->{page});
		}
		else {
			$params->{discoverError} = 1;
			$params->{discoverSort}  = $sortKey || Plugins::ArchiveLMA::Plugin::DEFAULT_DISCOVER_SORT();
			$params->{discoverPage}  = $page;
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
