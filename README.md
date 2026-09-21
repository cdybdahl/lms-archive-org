<img src="logo.png" width="96" height="96" alt="">

# lms-archive-org

A [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server / SqueezeboxServer)
plugin that browses and streams one or more [archive.org](https://archive.org) collections
directly — no downloading, no separate library import. Works through LMS's normal web UI,
Material Skin, and any Squeezebox/software player, since it's just a menu of remote streams.

It defaults to the [Aadam Jacobs Live Music Archive collection](https://archive.org/details/aadamjacobs)
(a few thousand live show recordings taped in Chicago, 1980s–2000s), but the collections are a
setting. Configure more than one and they're merged into a single catalog — Search, Browse by
Year/Artist/Venue, Recently Added, and Random Show all transparently span everything you've
added, since each is just one archive.org query with the collections OR'd together. There's no
local index or scheduled sync to keep in sync; every browse action queries archive.org live.

## Features

- **Search** — full-text search across show titles, artists, and venues
- **Browse by Year** — every year the collection spans, newest/oldest first
- **Browse by Artist** and **Browse by Venue** — both as an A–Z index (collections with thousands
  of distinct artists/venues would be unusable as one flat list)
- **Recently Added**
- **Random Show** — one tap to a random pick from the whole collection
- **Listen Later** — save whole shows to a list for one-tap return later (from a show's track
  list, not per-track)
- **Favorites (★)** — a second, separate saved-shows list for ones you love rather than ones
  you're queuing up; favorited shows show a ★ next to their title everywhere they appear (search,
  browse, Listen Later), and toggling is a tap from the show's track list, same as Listen Later
- **Play Entire Show / Add Entire Show to Queue** — one tap to queue every track of a show, not
  just individual tracks
- Show artwork, pulled from archive.org's thumbnail service
- Configurable collection list, merged into one catalog (Settings → Plugins → Archive.org Browser)
- Restricted to audio items, so pointing this at a mixed-media collection won't surface
  unplayable text/video entries
- Automatically retries once on a transient network hiccup before showing an error
- Individual tracks can also be saved to LMS's own built-in Favorites for one-tap replay later

## Requirements

- Lyrion Music Server or Logitech Media Server 7.0+
- A player (hardware Squeezebox, or software like `squeezelite`) — optional, but you'll want
  something to actually play audio to

## Installation

### Option 1: via repository URL (recommended)

1. Settings → Plugins → **Additional Repositories** → paste:
   ```
   https://raw.githubusercontent.com/cdybdahl/lms-archive-org/master/repository.xml
   ```
2. Save, then find **Archive.org Browser** in the plugin list below and check it.
3. Restart the server when prompted.

Future updates then show up as a normal plugin update, no manual re-copying.

### Option 2: manual copy

```sh
git clone https://github.com/cdybdahl/lms-archive-org.git ArchiveLMA
sudo cp -r ArchiveLMA /path/to/lms/Plugins/
sudo chown -R <lms-user>:<lms-group> /path/to/lms/Plugins/ArchiveLMA
sudo systemctl restart lyrionmusicserver   # or logitechmediaserver, squeezeboxserver, etc.
```

The folder **must** be named `ArchiveLMA` — that's what makes the Perl package
(`Plugins::ArchiveLMA::Plugin`) resolve. Where `Plugins/` actually lives depends on your install:

| Install type | Typical `Plugins/` location |
|---|---|
| Debian/Ubuntu package | `/var/lib/squeezeboxserver/Plugins/` (may be reached via a symlink at `/usr/share/squeezeboxserver/Plugins/`) |
| Docker | wherever your container mounts `config/plugin/` |
| macOS/Windows | inside the app's data directory, under `Plugins/` |

After restarting, enable it (if not already) under Settings → Plugins, and configure your
collections under Settings → Plugins → Archive.org Browser.

## Configuration

Settings → Plugins → **Archive.org Browser** → add each collection identifier you want included,
one at a time. Delete one by checking its box and saving.

The identifier is the last segment of the collection's archive.org URL — for
`archive.org/details/aadamjacobs`, that's `aadamjacobs`. Any archive.org collection works, not
just Live Music Archive ones, as long as its items have audio files. Add as many as you like;
they're merged into a single browsable catalog.

Don't know an identifier off-hand? The **Discover Collections** section further down the same
settings page lists other Live Music Archive collections by popularity, and lets you search by
band/taper name — click **Add** on any result to add it, no need to look up the identifier
yourself.

## How it works

The plugin talks to two public, unauthenticated archive.org endpoints:

- `advancedsearch.php` for search, year/artist browsing, and pagination
- `metadata/<identifier>` for a show's track listing

Playback URLs are archive.org's own `download/<identifier>/<file>` links — LMS streams them
directly, the same as any other internet radio-style source. Nothing is downloaded to the server;
nothing is mirrored. Listings are cached briefly (an hour for search results, a day for the full
artist list, a week for a show's track list) to keep browsing snappy and avoid hammering
archive.org's API.

## Releasing a new version

1. Bump `<version>` in `install.xml`.
2. Run `scripts/build_release.sh` — it builds `ArchiveLMA-<version>.zip` and prints its sha1.
3. `gh release create v<version> ArchiveLMA-<version>.zip` to attach it to a new GitHub release.
4. Update `repository.xml`'s `version`, `url`, and `sha` to match, commit, and push.

## Security

- No secrets or credentials anywhere in the plugin or its history.
- Zero external CPAN dependencies - only modules already bundled with LMS, plus core Perl. No
  third-party supply chain.
- Every outbound HTTP request targets a hardcoded `archive.org` URL; nothing in configuration or
  user input can redirect a request elsewhere.
- Collection identifiers entered in Settings are validated against archive.org's actual
  identifier shape (`[A-Za-z0-9_.-]+`) before being used to build a search query, so a malformed
  or malicious value is rejected rather than reaching the query string.
- Settings pages are already restricted by LMS itself to the local network/localhost - this
  plugin doesn't add any additional network-facing surface.

Found something? Open an issue.

## Roadmap

- [Submitted to the community plugin repository](https://github.com/LMS-Community/lms-plugin-repository/pull/83)
  so `repository.xml` isn't a manual add
- Integrating with LMS's own native Favorites system (long-press "Save to Favorites" on any node)
  rather than the plugin's own separate ★ list — LMS resolves a `link`-type favorite via a real
  HTTP fetch of an OPML feed, not a Perl callback, so this needs a dedicated web endpoint (e.g.
  serving a per-show OPML or M3U on demand) rather than just tagging the existing menu items
- Optional per-collection default sort order

## License

[MIT](LICENSE)

## Acknowledgments

- [Aadam Jacobs](https://archive.org/details/aadamjacobs) and the Internet Archive's
  [Live Music Archive](https://archive.org/details/etree) for the recordings this was built
  around
- The [Lyrion Music Server](https://lyrion.org/) project
