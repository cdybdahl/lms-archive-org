package Plugins::ArchiveLMA::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.archivelma');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ARCHIVELMA');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/ArchiveLMA/settings/basic.html');
}

# The collection list is managed by hand below rather than through the
# generic pref_* auto-save mechanism, since it's a variable-length list
# rather than a single value.
sub prefs {
	return ($prefs);
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		my $collections = $prefs->get('collections') || [];

		my @delete = @{ ref $params->{delete} eq 'ARRAY' ? $params->{delete} : [ $params->{delete} ] };
		if (@delete) {
			my %delete = map { $_ => 1 } grep { defined } @delete;
			@$collections = grep { !$delete{$_} } @$collections;
		}

		my $new = $params->{newcollection};
		if (defined $new) {
			$new =~ s/^\s+|\s+$//g;
			push @$collections, $new if length($new) && !grep { $_ eq $new } @$collections;
		}

		$prefs->set('collections', $collections);
	}

	$params->{prefs}->{collections} = $prefs->get('collections') || [];

	return $class->SUPER::handler($client, $params);
}

1;
