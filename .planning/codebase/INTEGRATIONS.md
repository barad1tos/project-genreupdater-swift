# External Integrations

**Analysis Date:** 2026-02-22

## Apple Music / Music.app

**Read path — MusicKit:**
- Framework: `MusicKit` (Apple, no third-party dependency)
- Client: `MusicLibraryReader` actor at `Packages/Services/Sources/Services/MusicLibraryReader.swift`
- Auth: `MusicAuthorization.request()` — prompts user; requires `NSAppleMusicUsageDescription` in `Info.plist`
- Entitlement: `com.apple.security.scripting-targets` → `com.apple.Music` with `com.apple.music.library.read`
- What it reads: all tracks in the user's Music library (`MusicLibraryRequest<Song>`)
- Performance: 10-50x faster than AppleScript for reads on large libraries

**Write path — AppleScript:**
- Mechanism: `NSUserAppleScriptTask` — Apple's sandbox-safe AppleScript executor
- Client: `AppleScriptBridge` actor at `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift`
- Entitlement: `com.apple.security.scripting-targets` → `com.apple.Music` with `com.apple.music.library.read-write`
- Framework: `Carbon.OpenScripting` for `NSAppleEventDescriptor` constants
- Scripts (compiled at build time, `.applescript` → `.scpt` via `osacompile`):
  - `Resources/Scripts/fetch_tracks.applescript` — bulk track fetch by all
  - `Resources/Scripts/fetch_tracks_by_ids.applescript` — targeted fetch by persistent ID
  - `Resources/Scripts/fetch_track_ids.applescript` — fetch all track IDs
  - `Resources/Scripts/update_property.applescript` — single property update (genre or year)
  - `Resources/Scripts/batch_update_tracks.applescript` — batch property update
- Script installation: `ScriptInstaller` actor (`Packages/Services/Sources/Services/Apple/ScriptInstaller.swift`) copies compiled `.scpt` files from app bundle to `~/Library/Application Scripts/<bundle-id>/` on first launch
- Serialization: actor ensures only one AppleScript executes at a time (prevents Music.app race conditions)

**Input safety:**
- `InputSanitizer` at `Packages/Services/Sources/Services/Apple/InputSanitizer.swift` has two distinct functions:
  - `sanitizeScriptCode()` — strips `; | & $ () {}` from AppleScript code fragments (NEVER use on track metadata)
  - `escapeStringValue()` — escapes `"` and `\` in data values (artist names, track titles, etc.)

## Apple Music Catalog Search API

- Framework: MusicKit (`MusicCatalogSearchRequest`)
- Client: `AppleMusicSearchClient` struct at `Packages/Services/Sources/Services/API/AppleMusicSearchClient.swift`
- Auth: Same MusicKit authorization as library reads
- Rate limiting: None implemented — Apple manages throttling internally
- What it returns: album release year (confidence 70%) and genre names from Apple Music catalog
- Graceful degradation: returns empty `YearResult` when MusicKit unauthorized (unit tests)
- Note: Artist activity period not exposed by MusicKit; those methods return `nil`

## MusicBrainz API

- Base URL: `https://musicbrainz.org/ws/2`
- Client: `MusicBrainzClient` struct at `Packages/Services/Sources/Services/API/MusicBrainzClient.swift`
- Auth: None (public API); User-Agent header required per MusicBrainz policy
- User-Agent format: `GenreUpdater/1.0 (<contact-email>; https://github.com/barad1tos/project-genreupdater-swift)`
- Rate limiting: `TokenBucketRateLimiter` — 1 request/second (`maxTokens: 1, refillInterval: .seconds(1)`)
- Endpoints used:
  - `GET /ws/2/release-group?query=artist:"<artist>" AND release:"<album>"&fmt=json&limit=5` — album year and type
  - `GET /ws/2/artist?query=artist:"<artist>"&fmt=json&limit=1` — artist activity period (life-span)
- Response format: JSON (via `?fmt=json` query param; default is XML)
- Confidence: 80% for "Album" primary type, 60% for other types
- HTTP errors handled: 200 (success), 400 (bad request), 503 (service unavailable)
- Models: `MusicBrainzModels.swift` at `Packages/Services/Sources/Services/API/MusicBrainzModels.swift`

## Discogs API

- Base URL: `https://api.discogs.com`
- Client: `DiscogsClient` struct at `Packages/Services/Sources/Services/API/DiscogsClient.swift`
- Auth: Personal Access Token (PAT) via `Authorization: Discogs token=<PAT>` header
- Token storage: macOS Keychain — service: `com.genreupdater.discogs`, account: `personal-access-token`
- Token management: `DiscogsClient.saveToken(_:)` (save) / `DiscogsClient.fromKeychain()` (load)
- Rate limiting: `TokenBucketRateLimiter` — 60 requests/minute (`maxTokens: 60, refillInterval: .seconds(60)`)
- Endpoints used:
  - `GET /database/search?artist=<artist>&release_title=<album>&type=master&per_page=5` — find master releases
  - `GET /masters/<id>` — master release details (year, genres, styles)
- Strategy: prefers master releases for canonical original release year; falls back to search result year
- Confidence: 75% for master release year, 60% for search result year
- HTTP errors handled: 200 (success), 401 (unauthorized), 429 (rate limited)
- Note: Artist activity period not available from Discogs; those methods return `nil`
- Models: `DiscogsModels.swift` at `Packages/Services/Sources/Services/API/DiscogsModels.swift`

## API Orchestration

- Orchestrator: `APIOrchestrator` actor at `Packages/Services/Sources/Services/API/APIOrchestrator.swift`
- Strategy: queries MusicBrainz, Discogs, and Apple Music **in parallel** with independent 15-second timeouts
- Aggregation: year with the highest combined confidence score across all sources wins
- Offline behavior: skips all API calls when `NetworkReachabilityMonitor` reports no connection
- Error isolation: any source failure or timeout is silently excluded; remaining results are used

## API Cache (GRDB / SQLite)

- Library: GRDB 7.10.0 (external dependency, `Packages/Services/Package.swift`)
- Client: `GRDBCacheService` actor at `Packages/Services/Sources/Services/Persistence/GRDB/GRDBCacheService.swift`
- Storage: `Application Support/GenreUpdater/api_cache.db` (SQLite file via `DatabasePool`)
- Schema: versioned migrations in `GRDBMigrations.swift` at `Packages/Services/Sources/Services/Persistence/GRDB/GRDBMigrations.swift`
- Tables:
  - `api_results` — per-source API results (artist, album, source, year, confidence, TTL)
  - `album_years` — aggregated album year cache (artist, album, year, confidence)
  - `generic_cache` — key-value blob cache for arbitrary serializable data
- TTL defaults: album years = 30 days, API responses = 15 minutes
- Concurrency: `DatabasePool` enables concurrent reads, serialized writes (via actor)

## Track State Persistence (SwiftData)

- Framework: SwiftData (Apple, macOS 14+)
- Models:
  - `PersistedTrack` at `Packages/Services/Sources/Services/Persistence/SwiftData/PersistedTrack.swift` — track processing state
  - `PersistedChangeLogEntry` at `Packages/Services/Sources/Services/Persistence/SwiftData/PersistedChangeLogEntry.swift` — change history
- Store access: `SwiftDataTrackStore` and `SwiftDataChangeLogStore` actors
- Container creation: `ModelContainerFactory` at `Packages/Services/Sources/Services/Persistence/SwiftData/ModelContainerFactory.swift`
- Known issue: SwiftData prevents clean process exit on headless runners — CI uses 120s background kill timeout for `swift test`

## StoreKit 2 / App Store Subscriptions

- Framework: StoreKit 2 (Apple)
- Client: `SubscriptionService` class at `Packages/Services/Sources/Services/Subscription/SubscriptionService.swift`
- Feature gating: `FeatureGate` at `Packages/Services/Sources/Services/Subscription/FeatureGate.swift`
- Product IDs (defined in `SubscriptionProductID`):
  - `genreupdater.weekpass` — non-renewing, 7-day, $1.99 (one purchase per 14-day cooldown)
  - `genreupdater.pro.monthly` — auto-renewable, monthly, $4.99
  - `genreupdater.pro.yearly` — auto-renewable, yearly, $29.99
- Tiers: Free / Week Pass / Pro (defined in `Core.Tier`)
- Local testing config: `Resources/GenreUpdater.storekit` (StoreKit configuration file for Xcode simulator)
- Transaction listener: background `Task` monitors StoreKit transaction updates
- Grace period: 16 days for Pro billing failures before downgrade

## iCloud KVS (NSUbiquitousKeyValueStore)

- Purpose: sync free-tier track usage counter across user's devices
- Entitlement: `com.apple.developer.ubiquity-kvstore-identifier` → `$(TeamIdentifierPrefix)$(CFBundleIdentifier)`
- Used by: `SubscriptionService` via `NSUbiquitousKeyValueStore.default`
- KVS keys: `freeTracksUsed`, `weekPassPurchaseCount`
- Fallback: `UserDefaults` used as local backup when iCloud unavailable

## Network Reachability

- Framework: Network framework (`NWPathMonitor`)
- Client: `NetworkReachabilityMonitor` actor at `Packages/Services/Sources/Services/Network/NetworkReachabilityMonitor.swift`
- Usage: injected into `APIOrchestrator` to skip API calls when offline

## Authentication & Secrets

| Secret | Storage | How Set |
|--------|---------|---------|
| Discogs PAT | macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) | User enters in Settings UI |
| MusicKit auth | OS-managed (no key needed) | User prompt on first launch |
| Discogs keychain keys | `com.genreupdater.discogs` / `personal-access-token` | Hardcoded service/account identifiers |

No server-side secrets. No backend infrastructure. All API calls are client-to-third-party-API.

## Webhooks & Callbacks

**Incoming:** None — no inbound webhooks.

**Outgoing:** None — no outbound webhooks. All network communication is client-initiated HTTP GET.

## Monitoring & Observability

**Logging:**
- macOS Unified Logging via `os.Logger` (subsystem: `com.genreupdater.app`)
- Pre-built category loggers: `AppLogger.general`, `AppLogger.appleScript`, `AppLogger.api`, `AppLogger.cache` (defined in `Packages/Core/Sources/Core/Infra/Logging.swift`)
- Privacy: user data (artist, track, album names) logged as `.private`; system identifiers logged as `.public`
- View logs: `log stream --predicate 'subsystem == "com.genreupdater.app"'` or Console.app

**Error Tracking:** None — no crash reporting service integrated.

**Analytics:** None — no analytics SDK integrated.

**Performance:**
- `SignpostMarkers` at `Packages/Core/Sources/Core/Infra/SignpostMarkers.swift` — `os.signpost` markers for Instruments profiling

---

*Integration audit: 2026-02-22*
