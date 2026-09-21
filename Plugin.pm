package Plugins::ArchiveLMA::Plugin;

# Browse and stream one or more archive.org collections as a single merged
# experience (defaults to "aadamjacobs", the Live Music Archive collection
# this plugin was originally built for).

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;
use Time::HiRes;

use constant DEFAULT_COLLECTION => 'aadamjacobs';
use constant SEARCH_URL        => 'https://archive.org/advancedsearch.php';
use constant METADATA_URL      => 'https://archive.org/metadata/';
use constant DOWNLOAD_URL      => 'https://archive.org/download/';
use constant IMAGE_URL         => 'https://archive.org/services/img/';
use constant PAGE_SIZE_DEFAULT => 50;
use constant LIST_CACHE_EXPIRY       => 3600;        # 1 hour for search/browse listings
use constant META_CACHE_EXPIRY       => 86400 * 7;   # 1 week for per-show track listings
use constant VALUE_LIST_CACHE_EXPIRY => 86400;       # 1 day for the full artist/venue lists
use constant ALL_ITEMS_ROWS          => 4000;        # comfortably above the collection's ~3400 shows
use constant HTTP_MAX_RETRIES    => 1;           # archive.org occasionally hiccups; one silent retry covers it
use constant HTTP_RETRY_DELAY    => 1.5;         # seconds before retrying
use constant DISCOVER_ROWS       => 100;         # collections shown per Settings > Discover search

# Preferred playback format, in priority order - archive.org usually carries
# the same recording in several formats and we only want one file per track.
my @FORMAT_PRIORITY = ('VBR MP3', 'MP3', '128Kbps MP3', 'Ogg Vorbis', 'Flac');

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.archivelma',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $prefs = preferences('plugin.archivelma');

sub getDisplayName { 'PLUGIN_ARCHIVELMA' }

sub _collections {
	my $collections = $prefs->get('collections');
	return @$collections if $collections && @$collections;
	return (DEFAULT_COLLECTION);
}

sub _listenLater {
	return $prefs->get('listenLater') || [];
}

sub _isInListenLater {
	my $identifier = shift;
	return !!grep { $_->{identifier} eq $identifier } @{ _listenLater() };
}

sub _addToListenLater {
	my ($identifier, $name, $name2) = @_;
	my $list = _listenLater();
	return if grep { $_->{identifier} eq $identifier } @$list;
	unshift @$list, { identifier => $identifier, name => $name, name2 => $name2 };
	$prefs->set('listenLater', $list);
}

sub _removeFromListenLater {
	my $identifier = shift;
	my $list = _listenLater();
	@$list = grep { $_->{identifier} ne $identifier } @$list;
	$prefs->set('listenLater', $list);
}

# Restricts to playable media - matters once the collection list is
# configurable, since a non-audio (e.g. text/video) collection would
# otherwise produce "shows" whose tracklist is just an empty Play All /
# Add All screen. Multiple collections are OR'd together so every browse
# path (search, year, artist, venue, random) transparently spans all of
# them as one merged catalog - archive.org's search index handles this
# natively, so there's no local copy of the catalog to keep in sync.
sub _baseQuery {
	my @collections = _collections();
	my $collectionFilter = '(' . join(' OR ', map { "collection:$_" } @collections) . ')';
	return "$collectionFilter AND mediatype:(audio OR etree)";
}

# Fetch and JSON-decode a URL, with one silent retry on a transient network
# failure (archive.org occasionally times out or hiccups) before giving up.
sub _getJSON {
	my ($url, $cacheOpts, $onSuccess, $onError, $retriesLeft) = @_;
	$retriesLeft = HTTP_MAX_RETRIES unless defined $retriesLeft;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { from_json($response->content) };

			if ($@ || !$result) {
				$log->error("Failed to parse JSON from $url: $@");
				return $onError->('bad JSON');
			}

			$onSuccess->($result);
		},
		sub {
			my (undef, $error) = @_;

			if ($retriesLeft > 0) {
				$log->warn("Request failed ($error), retrying: $url");
				Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + HTTP_RETRY_DELAY, sub {
					_getJSON($url, $cacheOpts, $onSuccess, $onError, $retriesLeft - 1);
				});
			}
			else {
				$log->error("Request failed after retry: $url ($error)");
				$onError->($error);
			}
		},
		$cacheOpts,
	)->get($url);
}

sub initPlugin {
	my $class = shift;

	$prefs->init({ collections => [ DEFAULT_COLLECTION ], listenLater => [] });

	# One-time migration from the earlier single-collection pref.
	$prefs->migrate(1, sub {
		if (my $old = $prefs->get('collection')) {
			$prefs->set('collections', [ $old ]);
		}
		1;
	});

	if (main::WEBUI) {
		require Plugins::ArchiveLMA::Settings;
		Plugins::ArchiveLMA::Settings->new();
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'archivelma',
		is_app => 1,
	);
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	$cb->({
		items => [
			{
				name => cstring($client, 'PLUGIN_ARCHIVELMA_SEARCH'),
				type => 'search',
				url  => \&searchHandler,
			},
			{
				name => cstring($client, 'PLUGIN_ARCHIVELMA_BY_YEAR'),
				type => 'link',
				url  => \&yearListHandler,
			},
			{
				name        => cstring($client, 'PLUGIN_ARCHIVELMA_BY_ARTIST'),
				type        => 'link',
				url         => \&letterListHandler,
				passthrough => [ { field => 'creator' } ],
			},
			{
				name        => cstring($client, 'PLUGIN_ARCHIVELMA_BY_VENUE'),
				type        => 'link',
				url         => \&letterListHandler,
				passthrough => [ { field => 'venue' } ],
			},
			{
				name => cstring($client, 'PLUGIN_ARCHIVELMA_RECENT'),
				type => 'link',
				url  => \&showListHandler,
				passthrough => [ { sort => 'addeddate desc' } ],
			},
			{
				name => cstring($client, 'PLUGIN_ARCHIVELMA_RANDOM'),
				type => 'link',
				url  => \&randomShowHandler,
			},
			{
				name => cstring($client, 'PLUGIN_ARCHIVELMA_LISTEN_LATER'),
				type => 'link',
				url  => \&listenLaterHandler,
			},
		],
	});
}

sub listenLaterHandler {
	my ($client, $cb, $args) = @_;

	my @items = map {
		my $show = $_;
		{
			name        => $show->{name},
			name2       => $show->{name2},
			type        => 'link',
			image       => IMAGE_URL . $show->{identifier},
			url         => \&trackListHandler,
			passthrough => [ { identifier => $show->{identifier} } ],
		};
	} @{ _listenLater() };

	push @items, { name => cstring($client, 'EMPTY') } unless @items;

	$cb->({ items => \@items });
}

# archive.org's facet API currently rejects arbitrary facet fields, so instead
# of faceting on "year" we just look up the oldest and newest show dates and
# build a plain year list from that span. A handful of years might end up
# empty (showListHandler just displays "EMPTY" for those).
sub yearListHandler {
	my ($client, $cb, $args) = @_;

	_yearBound('asc', sub {
		my $minYear = shift;
		return _yearError($client, $cb) unless $minYear;

		_yearBound('desc', sub {
			my $maxYear = shift;
			return _yearError($client, $cb) unless $maxYear;

			my @items = map {
				my $year = $_;
				{
					name        => $year,
					type        => 'link',
					url         => \&showListHandler,
					passthrough => [ { query => "year:$year", sort => 'date asc' } ],
				};
			} reverse ($minYear .. $maxYear);

			$cb->({ items => \@items });
		});
	});
}

sub _yearBound {
	my ($direction, $done) = @_;

	my $url = SEARCH_URL . '?' . join('&',
		'q=' . uri_escape_utf8(_baseQuery()),
		'rows=1',
		'output=json',
		'fl[]=year',
		'sort[]=' . uri_escape_utf8("date $direction"),
	);

	_getJSON($url, { cache => 1, expires => 86400 },
		sub {
			my $result = shift;
			$done->($result->{response}{docs}[0]{year});
		},
		sub {
			$log->error("Failed to fetch $direction year bound: $_[0]");
			$done->(undef);
		},
	);
}

sub _yearError {
	my ($client, $cb) = @_;
	$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
}

# Thousands of distinct artists/venues is too many for a flat list, so we
# show an A-Z index first and only list the matching values once a letter
# is picked. Shared by "Browse by Artist" (field=creator) and "Browse by
# Venue" (field=venue).
sub letterListHandler {
	my ($client, $cb, $args, $passthrough) = @_;
	my $field = $passthrough->{field};

	_withAllValues($field, sub {
		my $values = shift;

		if (!@$values) {
			return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
		}

		my %counts;
		$counts{ _letterFor($_) }++ for @$values;

		my @items = map {
			my $letter = $_;
			{
				name        => "$letter ($counts{$letter})",
				type        => 'link',
				url         => \&valueListHandler,
				passthrough => [ { field => $field, letter => $letter } ],
			};
		} sort keys %counts;

		$cb->({ items => \@items });
	});
}

sub valueListHandler {
	my ($client, $cb, $args, $passthrough) = @_;
	my ($field, $letter) = @{$passthrough}{qw(field letter)};

	_withAllValues($field, sub {
		my $values = shift;

		my @items = map {
			my $value = $_;
			{
				name        => $value,
				type        => 'link',
				url         => \&showListHandler,
				passthrough => [ { query => "$field:" . _phrase($value), sort => 'date asc' } ],
			};
		} grep { _letterFor($_) eq $letter } @$values;

		push @items, { name => cstring($client, 'EMPTY') } unless @items;

		$cb->({ items => \@items });
	});
}

# Fetches every show's value for one field (creator or venue) once, deduped
# and sorted - cached for a day since a taper's back catalog barely changes
# from one day to the next.
sub _withAllValues {
	my ($field, $done) = @_;

	my $url = SEARCH_URL . '?' . join('&',
		'q=' . uri_escape_utf8(_baseQuery()),
		'rows=' . ALL_ITEMS_ROWS,
		'output=json',
		"fl[]=$field",
	);

	_getJSON($url, { cache => 1, expires => VALUE_LIST_CACHE_EXPIRY },
		sub {
			my $result = shift;

			if (!$result->{response}) {
				$log->error("Unexpected $field list response");
				return $done->([]);
			}

			my %seen;
			my @values =
				sort { lc($a) cmp lc($b) }
				grep { $_ && !$seen{$_}++ }
				map { $_->{$field} } @{ $result->{response}{docs} };

			$done->(\@values);
		},
		sub {
			$log->error("Failed to fetch $field list: $_[0]");
			$done->([]);
		},
	);
}

# Powers the Settings > Discover panel: lists other archive.org collections
# a user could add, so they don't have to already know an identifier to try
# it. Restricted to collection:etree (the Live Music Archive's umbrella
# collection of per-artist/taper sub-collections) since that's what this
# plugin's browse-by-year/artist/venue screens are built around; an
# arbitrary mediatype:collection search would surface mostly non-audio
# collections. Sorted by downloads as a simple popularity signal.
sub discoverCollections {
	my ($query, $done) = @_;

	my $q = 'mediatype:collection AND collection:etree';

	my $term = _sanitizeDiscoverTerm($query);
	if (length $term) {
		$q .= ' AND (title:(' . $term . ') OR identifier:(' . $term . '))';
	}

	my $url = SEARCH_URL . '?' . join('&',
		'q=' . uri_escape_utf8($q),
		'rows=' . DISCOVER_ROWS,
		'output=json',
		'fl[]=identifier', 'fl[]=title', 'fl[]=downloads',
		'sort[]=' . uri_escape_utf8('downloads desc'),
	);

	_getJSON($url, { cache => 1, expires => LIST_CACHE_EXPIRY },
		sub {
			my $result = shift;

			if (!$result->{response}) {
				$log->error("Unexpected discover response");
				return $done->(undef);
			}

			my $docs = $result->{response}{docs} || [];

			$done->({
				total   => $result->{response}{numFound} || scalar @$docs,
				results => [ map {
					{
						identifier => $_->{identifier},
						title      => $_->{title} || $_->{identifier},
						downloads  => $_->{downloads} || 0,
					};
				} @$docs ],
			});
		},
		sub {
			$log->error("Discover search failed: $_[0]");
			$done->(undef);
		},
	);
}

# Solr's query syntax has too many special characters (colons, parens,
# boolean operators, ...) to safely pass user input through unescaped, so
# rather than escape them all we just strip everything but the characters
# an archive.org title or identifier could plausibly contain.
sub _sanitizeDiscoverTerm {
	my $term = shift;
	return '' unless defined $term;

	$term =~ s/[^A-Za-z0-9 '-]//g;
	$term =~ s/^\s+|\s+$//g;

	return $term;
}

sub _letterFor {
	my $letter = uc(substr(shift, 0, 1));
	return $letter =~ /^[A-Z]$/ ? $letter : '#';
}

sub _phrase {
	my $s = shift;
	$s =~ s/(["\\])/\\$1/g;
	return qq{"$s"};
}

sub searchHandler {
	my ($client, $cb, $args) = @_;
	my $search = $args->{search};

	showListHandler($client, $cb, $args, {
		query => qq{(title:($search) OR creator:($search) OR venue:($search))},
		sort  => 'date asc',
	});
}

sub showListHandler {
	my ($client, $cb, $args, $passthrough) = @_;
	my $opts = $passthrough || {};

	my $index    = $args->{index} || 0;
	my $quantity = $args->{quantity} || PAGE_SIZE_DEFAULT;
	my $page     = int($index / $quantity) + 1;

	my $q = _baseQuery();
	$q .= ' AND (' . $opts->{query} . ')' if $opts->{query};

	my @params = (
		'q=' . uri_escape_utf8($q),
		'rows=' . $quantity,
		'page=' . $page,
		'output=json',
		'fl[]=identifier', 'fl[]=title', 'fl[]=creator', 'fl[]=date', 'fl[]=venue', 'fl[]=coverage',
	);
	push @params, 'sort[]=' . uri_escape_utf8($opts->{sort}) if $opts->{sort};

	my $url = SEARCH_URL . '?' . join('&', @params);

	_getJSON($url, { cache => 1, expires => LIST_CACHE_EXPIRY },
		sub {
			my $result = shift;

			if (!$result->{response}) {
				$log->error("Unexpected search response");
				return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
			}

			my $docs  = $result->{response}{docs} || [];
			my $total = $result->{response}{numFound} || scalar @$docs;

			my @items = map {
				my $doc = $_;
				my $date = $doc->{date};
				$date =~ s/T.*$// if $date;
				my $subtitle = join(' - ', grep { $_ } ($date, $doc->{venue} || $doc->{coverage}));
				{
					name        => $doc->{title} || $doc->{identifier},
					name2       => $subtitle,
					type        => 'link',
					image       => IMAGE_URL . $doc->{identifier},
					url         => \&trackListHandler,
					passthrough => [ { identifier => $doc->{identifier} } ],
				};
			} @$docs;

			push @items, { name => cstring($client, 'EMPTY') } unless @items;

			$cb->({ items => \@items, total => $total, offset => $index });
		},
		sub {
			$log->error("Search request failed: $_[0]");
			$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
		},
	);
}

sub trackListHandler {
	my ($client, $cb, $args, $passthrough) = @_;
	my $identifier = $passthrough->{identifier};

	_getJSON(METADATA_URL . $identifier, { cache => 1, expires => META_CACHE_EXPIRY },
		sub {
			my $result = shift;

			if (!$result->{files}) {
				$log->error("Unexpected metadata response for $identifier");
				return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
			}

			my $meta = $result->{metadata} || {};
			my $showName = $meta->{title} || $identifier;
			my $showDate = $meta->{date};
			$showDate =~ s/T.*$// if $showDate;
			my $showName2 = join(' - ', grep { $_ } ($showDate, $meta->{venue} || $meta->{coverage}));

			# Archive.org carries each track in several formats; keep only the
			# best-priority file per track so we don't list duplicates.
			my %byTrack;
			for my $file (@{ $result->{files} }) {
				my $priority = _formatPriority($file->{format});
				next unless defined $priority;

				my $track = $file->{track};
				my $sortKey = (defined $track && $track =~ /^\d+$/) ? sprintf('%03d', $track) : $file->{name};

				if (!$byTrack{$sortKey} || $priority < $byTrack{$sortKey}{priority}) {
					my $title = $file->{title};
					$title = undef if $title && lc($title) eq 'untitled';

					$byTrack{$sortKey} = {
						priority => $priority,
						name     => $title || (defined $track ? "Track $track" : $file->{name}),
						file     => $file->{name},
						duration => _parseDuration($file->{length}),
					};
				}
			}

			my @items = map {
				my $t = $byTrack{$_};
				{
					name      => $t->{name},
					type      => 'audio',
					play      => DOWNLOAD_URL . $identifier . '/' . uri_escape_utf8($t->{file}),
					image     => IMAGE_URL . $identifier,
					duration  => $t->{duration},
					on_select => 'play',
				};
			} sort keys %byTrack;

			if (@items) {
				my @urls = map { $_->{play} } @items;
				unshift @items, _listenLaterItem($client, $identifier, $showName, $showName2);
				unshift @items, _addAllItem($client, \@urls);
				unshift @items, _playAllItem($client, \@urls);
			}
			else {
				push @items, { name => cstring($client, 'EMPTY') };
			}

			$cb->({ items => \@items });
		},
		sub {
			$log->error("Metadata request failed for $identifier: $_[0]");
			$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
		},
	);
}

sub randomShowHandler {
	my ($client, $cb, $args) = @_;

	my $countUrl = SEARCH_URL . '?' . join('&',
		'q=' . uri_escape_utf8(_baseQuery()),
		'rows=0',
		'output=json',
	);

	_getJSON($countUrl, { cache => 1, expires => LIST_CACHE_EXPIRY },
		sub {
			my $result = shift;
			my $total  = $result->{response}{numFound};

			if (!$total) {
				return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
			}

			my $pickUrl = SEARCH_URL . '?' . join('&',
				'q=' . uri_escape_utf8(_baseQuery()),
				'rows=1',
				'page=' . (int(rand($total)) + 1),
				'output=json',
				'fl[]=identifier',
			);

			# Not cached - every pick should be able to land on a different show.
			_getJSON($pickUrl, {},
				sub {
					my $pickResult = shift;
					my $identifier = $pickResult->{response}{docs}[0]{identifier};

					if (!$identifier) {
						return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
					}

					trackListHandler($client, $cb, $args, { identifier => $identifier });
				},
				sub {
					$log->error("Random pick request failed: $_[0]");
					$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
				},
			);
		},
		sub {
			$log->error("Random count request failed: $_[0]");
			$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
		},
	);
}

sub _listenLaterItem {
	my ($client, $identifier, $name, $name2) = @_;

	my $inList = _isInListenLater($identifier);

	return {
		name       => cstring($client, $inList ? 'PLUGIN_ARCHIVELMA_REMOVE_LISTEN_LATER' : 'PLUGIN_ARCHIVELMA_ADD_LISTEN_LATER'),
		type       => 'link',
		# Without this, Jive-style clients (Material Skin, apps, remotes) navigate
		# into a new screen for this action and are left looking at it empty once
		# the showBriefly confirmation item below is stripped out for the toast -
		# nextWindow tells them to pop back to the track list instead.
		nextWindow => 'parent',
		url        => sub {
			my ($client, $cb) = @_;

			if ($inList) {
				_removeFromListenLater($identifier);
				$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_REMOVED_LISTEN_LATER'), showBriefly => 1 } ] });
			}
			else {
				_addToListenLater($identifier, $name, $name2);
				$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ADDED_LISTEN_LATER'), showBriefly => 1 } ] });
			}
		},
	};
}

sub _playAllItem {
	my ($client, $urls) = @_;

	return {
		name       => cstring($client, 'PLUGIN_ARCHIVELMA_PLAY_ALL'),
		type       => 'link',
		nextWindow => 'nowPlaying',
		url        => sub {
			my ($client, $cb) = @_;

			if (!$client) {
				return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
			}

			$client->execute([ 'playlist', 'playtracks', 'listRef', $urls ]);

			$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_PLAYING'), showBriefly => 1, nowPlaying => 1 } ] });
		},
	};
}

sub _addAllItem {
	my ($client, $urls) = @_;

	return {
		name       => cstring($client, 'PLUGIN_ARCHIVELMA_ADD_ALL'),
		type       => 'link',
		nextWindow => 'parent',
		url        => sub {
			my ($client, $cb) = @_;

			if (!$client) {
				return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
			}

			$client->execute([ 'playlist', 'addtracks', 'listRef', $urls ]);

			$cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ADDED'), showBriefly => 1 } ] });
		},
	};
}

sub _formatPriority {
	my $format = shift // '';
	for my $i (0 .. $#FORMAT_PRIORITY) {
		return $i if $format eq $FORMAT_PRIORITY[$i];
	}
	return undef;
}

sub _parseDuration {
	my $length = shift;
	return undef unless defined $length;

	if ($length =~ /^(\d+):(\d+):(\d+(?:\.\d+)?)$/) {
		return $1 * 3600 + $2 * 60 + $3;
	}
	elsif ($length =~ /^(\d+):(\d+(?:\.\d+)?)$/) {
		return $1 * 60 + $2;
	}
	elsif ($length =~ /^[\d.]+$/) {
		return int($length);
	}
	return undef;
}

1;
