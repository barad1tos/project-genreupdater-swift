# Privacy Policy — Genre Updater

**Effective date:** 2026-02-21
**Last updated:** 2026-02-21

## Data Collection

Genre Updater does **not** collect, store, or transmit any
personal data. There is no telemetry, analytics, crash
reporting, or tracking of any kind.

## Local Processing

All music library analysis, genre determination, and year
scoring happen entirely on your Mac. Your music metadata
never leaves your device except for the API lookups
described below.

## Network Requests

The app makes outbound requests to three music metadata
services to look up album release years and genres:

| Service | Data Sent | Purpose |
|---------|-----------|---------|
| MusicBrainz | Artist + album name | Year lookup |
| Discogs | Artist + album name | Year lookup |
| Apple Music Search | Artist + album name | Genre + year |

Only the artist name and album title are sent. No account
IDs, device IDs, or other identifying information is
included in these requests.

## Keychain

API keys for Discogs (optional, user-provided) are stored
in the macOS Keychain. They are never transmitted to any
server other than the Discogs API.

## iCloud Key-Value Storage

A single integer counter (number of free tracks processed)
is synced via iCloud KVS to enforce the free tier limit
across devices. No music metadata is synced.

## Third-Party SDKs

Genre Updater uses no third-party analytics, advertising,
or tracking SDKs. The only external dependency is GRDB
(a local SQLite library) which makes no network requests.

## Children's Privacy

The app does not knowingly collect information from
children under 13.

## Contact

For privacy questions, contact the developer via the
App Store support link.
