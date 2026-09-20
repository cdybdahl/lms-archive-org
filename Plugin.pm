package Plugins::ArchiveLMA::Plugin;

# Browse and stream any archive.org collection (defaults to "aadamjacobs",
# the Live Music Archive collection this plugin was originally built for).

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
use constant PAGE_SIZE_DEFAULT => 50;
use constant LIST_CACHE_EXPIRY   => 3600;        # 1 hour for search/browse listings
use constant META_CACHE_EXPIRY   => 86400 * 7;   # 1 week for per-show track listings
use constant ARTIST_CACHE_EXPIRY => 86400;       # 1 day for the full artist list
use constant ALL_ITEMS_ROWS      => 4000;        # comfortably above the collection's ~3400 shows
use constant HTTP_MAX_RETRIES    => 1;           # archive.org occasionally hiccups; one silent retry covers it
use constant HTTP_RETRY_DELAY    => 1.5;         # seconds before retrying

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

sub _collection {
	return $prefs->get('collection') || DEFAULT_COLLECTION;
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

	$prefs->init({ collection => DEFAULT_COLLECTION });

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
				name => cstring($client, 'PLUGIN_ARCHIVELMA_BY_ARTIST'),
				type => 'link',
				url  => \&artistLetterListHandler,
			},
			{
				name => cstring($client, 'PLUGIN_ARCHIVELMA_RECENT'),
				type => 'link',
				url  => \&showListHandler,
				passthrough => [ { sort => 'addeddate desc' } ],
			},
		],
	});
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
		'q=' . uri_escape_utf8('collection:' . _collection()),
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

# ~1,800 distinct artists is too many for a flat list, so we show an A-Z
# index first and only list the matching artists once a letter is picked.
sub artistLetterListHandler {
	my ($client, $cb, $args) = @_;

	_withAllCreators(sub {
		my $creators = shift;

		if (!@$creators) {
			return $cb->({ items => [ { name => cstring($client, 'PLUGIN_ARCHIVELMA_ERROR') } ] });
		}

		my %counts;
		$counts{ _letterFor($_) }++ for @$creators;

		my @items = map {
			my $letter = $_;
			{
				name        => "$letter ($counts{$letter})",
				type        => 'link',
				url         => \&artistListHandler,
				passthrough => [ { letter => $letter } ],
			};
		} sort keys %counts;

		$cb->({ items => \@items });
	});
}

sub artistListHandler {
	my ($client, $cb, $args, $passthrough) = @_;
	my $letter = $passthrough->{letter};

	_withAllCreators(sub {
		my $creators = shift;

		my @items = map {
			my $artist = $_;
			{
				name        => $artist,
				type        => 'link',
				url         => \&showListHandler,
				passthrough => [ { query => 'creator:' . _phrase($artist), sort => 'date asc' } ],
			};
		} grep { _letterFor($_) eq $letter } @$creators;

		push @items, { name => cstring($client, 'EMPTY') } unless @items;

		$cb->({ items => \@items });
	});
}

# Fetches every show's creator once, deduped and sorted - cached for a day
# since a taper's back catalog barely changes from one day to the next.
sub _withAllCreators {
	my $done = shift;

	my $url = SEARCH_URL . '?' . join('&',
		'q=' . uri_escape_utf8('collection:' . _collection()),
		'rows=' . ALL_ITEMS_ROWS,
		'output=json',
		'fl[]=creator',
	);

	_getJSON($url, { cache => 1, expires => ARTIST_CACHE_EXPIRY },
		sub {
			my $result = shift;

			if (!$result->{response}) {
				$log->error("Unexpected creator list response");
				return $done->([]);
			}

			my %seen;
			my @creators =
				sort { lc($a) cmp lc($b) }
				grep { $_ && !$seen{$_}++ }
				map { $_->{creator} } @{ $result->{response}{docs} };

			$done->(\@creators);
		},
		sub {
			$log->error("Failed to fetch creator list: $_[0]");
			$done->([]);
		},
	);
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

	my $q = 'collection:' . _collection();
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
					duration  => $t->{duration},
					on_select => 'play',
				};
			} sort keys %byTrack;

			if (@items) {
				my @urls = map { $_->{play} } @items;
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

sub _playAllItem {
	my ($client, $urls) = @_;

	return {
		name => cstring($client, 'PLUGIN_ARCHIVELMA_PLAY_ALL'),
		type => 'link',
		url  => sub {
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
		name => cstring($client, 'PLUGIN_ARCHIVELMA_ADD_ALL'),
		type => 'link',
		url  => sub {
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
