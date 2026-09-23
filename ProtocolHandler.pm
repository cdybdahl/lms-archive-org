package Plugins::ArchiveLMA::ProtocolHandler;

# Handles archivelma:// URLs, each of which just wraps a real archive.org
# download URL together with a dB gain value:
#
#   archivelma://<gainDb>/<uri-escaped real https:// URL>
#
# This class exists purely to hook trackGain() - see the "Allow plugins to
# override replaygain" check in Slim::Player::ReplayGain::fetchGainMode -
# so the per-collection volume boost configured in Settings can be applied
# without transcoding through SoX, and works the same on every player type.
#
# Plugin.pm only ever builds one of these URLs when gain compensation is on
# and the item's collection has a non-zero gain configured; otherwise it
# hands out the plain archive.org URL and this class is never involved.

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use URI::Escape qw(uri_escape_utf8 uri_unescape);

use Slim::Music::Info;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.archivelma',
	'defaultLevel' => 'ERROR',
	'description'  => 'PLUGIN_ARCHIVELMA',
});

Slim::Player::ProtocolHandlers->registerHandler('archivelma', __PACKAGE__);

sub wrapUrl {
	my ($class, $realUrl, $gainDb) = @_;
	return 'archivelma://' . $gainDb . '/' . uri_escape_utf8($realUrl);
}

sub crackUrl {
	my ($class, $url) = @_;

	my ($gainDb, $encoded) = $url =~ m{^archivelma://([^/]+)/(.+)$};
	return unless defined $encoded;

	return (uri_unescape($encoded), $gainDb + 0);
}

# Resolves the real archive.org URL into $song->streamUrl before any
# direct-stream decision is made - canDirectStreamSong (inherited from
# Slim::Player::Protocols::HTTP) and everything else downstream reads
# $song->streamUrl rather than the track's own (archivelma://) url, so this
# is the one place that needs to unwrap it.
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my ($realUrl) = $class->crackUrl($song->currentTrack->url);

	if (!$realUrl) {
		$log->error('Malformed archivelma:// URL: ' . $song->currentTrack->url);
		return $errorCb->('Invalid archive.org gain-wrapped URL');
	}

	$song->streamUrl($realUrl);
	$successCb->();
}

sub new {
	my ($class, $args) = @_;

	my $streamUrl = $args->{song}->streamUrl || return;

	return $class->SUPER::new({ %$args, url => $streamUrl });
}

sub getFormatForURL {
	my ($class, $url) = @_;

	my ($realUrl) = $class->crackUrl($url);
	return Slim::Music::Info::typeFromSuffix($realUrl || $url, 'mp3');
}

# The duration for every track we hand out is already known and set on the
# OPML item (see Plugin.pm's trackListHandler), so there's nothing to probe
# for - and the archivelma:// URL itself isn't fetchable, only the real URL
# it wraps.
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack);
}

# The whole reason this class exists: return the configured per-collection
# gain (in dB) that Plugin.pm baked into the URL, overriding LMS's normal
# ReplayGain logic for this track.
sub trackGain {
	my ($class, $client, $url) = @_;

	my (undef, $gainDb) = $class->crackUrl($url);
	return $gainDb;
}

1;
