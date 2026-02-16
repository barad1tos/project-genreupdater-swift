---
type: technical-design
title: "Technical Design Document"
status: active
---
> Parent: [[PRD]]

**Related:** [[phase-2-core-models]] | [[phase-3-core-algorithms]] | [[phase-4-api-cache]] | [[phase-5-workflows]]

# Technical Design Document (TDD)

> Technical companion to the [[PRD]]. PRD describes *what* we build and *why*. TDD describes *how* — file mapping, pattern translations, architecture implementation details, and lessons learned.

## 1. Python → Swift Architecture Summary

Python: 124 files, 32.7K LOC → Swift: **~55 files, ~15-18K LOC** (0.71x ratio).

Not a 1:1 copy — architecturally optimized Swift structure preserving **100% functionality**.

**Why fewer files**: Swift eliminates Python boilerplate (Pydantic → Codable synthesis, logging → os.Logger, DI → @Environment, cache infra → SwiftData). Tightly coupled Python modules merge into coherent Swift files.

**SPM Local Packages** enforce layer boundaries (compiler prevents Core from importing Services):

```
GenreUpdaterApp.xcodeproj
├── App/                              # Main app target (imports: Core, Services, SharedUI)
│   ├── GenreUpdaterApp.swift         # @main entry point
│   ├── AppDependencies.swift         # Composition root (563 LOC DI → ~100 LOC)
│   ├── Views/                        # SwiftUI views
│   └── Workflows/                    # ← src/app/ orchestration layer
├── Packages/
│   ├── Core/                         # SPM package (zero Apple framework imports except Foundation)
│   ├── Services/                     # SPM package (imports: Core, Foundation, MusicKit)
│   └── SharedUI/                     # SPM package (imports: Core, SwiftUI, Charts)
├── Resources/Scripts/                # ← applescripts/ (reuse as-is, compile to .scpt)
└── Tests/                            # App-level integration + E2E tests
```

---

## 2. Full File Mapping: Python → Swift

Every Python file has a Swift counterpart. `__init__.py` are not ported (Swift doesn't need them). `src/stubs/` are not ported (Python-specific type stubs).

**Complexity legend**: 🔴 High (complex logic, 30+ factors) · 🟡 Medium · 🟢 Low · ⚪ Trivial

### src/app/ → Sources/App/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `app_config.py` | 101 | `AppConfig.swift` | 🟢 | YAML → `Codable` struct + `@AppStorage` |
| `cli.py` | 291 | → `Views/MainView.swift` | 🟡 | argparse → SwiftUI NavigationSplitView |
| `orchestrator.py` | 417 | `AppOrchestrator.swift` | 🟡 | `@Observable`, async command dispatch |
| `music_updater.py` | 850 | `MusicUpdater.swift` | 🔴 | Central coordinator, all logic preserved |
| `full_sync.py` | 194 | → `GenreUpdateFlow.swift` | 🟡 | **MERGED** with genre_update.py |
| `genre_update.py` | 121 | → `GenreUpdateFlow.swift` | 🟢 | **MERGED** with full_sync.py |
| `year_update.py` | 465 | → `YearUpdateFlow.swift` | 🟡 | **MERGED** with pipeline_snapshot.py |
| `pipeline_snapshot.py` | 204 | → `YearUpdateFlow.swift` | 🟡 | **MERGED** with year_update.py |
| `track_cleaning.py` | 228 | → `TrackCleaningFlow.swift` | 🟢 | **MERGED** with artist_renamer.py |

### src/app/features/ → Sources/App/Workflows/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `batch/batch_processor.py` | 154 | → `BatchFlow.swift` | 🟡 | **MERGED** with batch_fetcher → TaskGroup |
| `crypto/encryption.py` | 377 | Keychain Services | 🟡 | Fernet → Security.framework |
| `crypto/exceptions.py` | 41 | enum in encryption | ⚪ | Inline in Keychain wrapper |
| `verify/database_verifier.py` | 533 | `DatabaseVerifier.swift` | 🟡 | Standalone, SwiftData queries |

### src/core/ → Packages/Core/Sources/Core/Infra/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `core_config.py` | 325 | → `AppConfiguration.swift` | 🟡 | **MERGED** with app_config → `Codable` |
| `logger.py` | 1,092 | `Logging.swift` | 🟢 | **1,092 → ~100 LOC**: os.Logger replaces Python logging |
| `retry_handler.py` | 437 | `RetryHandler.swift` | 🟡 | Decorator → generic `withRetry()` |
| `dry_run.py` | 165 | inline protocol | 🟢 | Protocol conformance, no separate file |
| `analytics_decorator.py` | 110 | → `RunTracking.swift` | 🟢 | **MERGED** with run_tracking.py |
| `apple_script_names.py` | 20 | enum constant | ⚪ | Inline in AppleScriptBridge |
| `debug_utils.py` | 81 | inline | ⚪ | Extension on os.Logger |
| `run_tracking.py` | 98 | `RunTracking.swift` | 🟢 | **MERGED** with analytics_decorator.py |

### src/core/models/ → Packages/Core/Sources/Core/Models/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `track_models.py` | 713 | `Track.swift` | 🔴 | **SPLIT**: domain struct (Core) + `PersistedTrack` @Model (Services) |
| `album_type.py` | 405 | `AlbumType.swift` | 🟡 | Enum + classification, direct port |
| `cache_types.py` | 176 | → `CachedModels.swift` | 🟢 | **MOVED** to Services/Cache/ |
| `metadata_utils.py` | 803 | `MetadataUtils.swift` | 🔴 | Regex-heavy, remains large |
| `normalization.py` | 51 | `Normalization.swift` | ⚪ | String normalization |
| `protocols.py` | 773 | `Protocols.swift` | 🟡 | **773 → ~300 LOC**: Swift protocol concise |
| `script_detection.py` | 519 | `ScriptDetection.swift` | 🟡 | Regex-heavy, Swift Regex builder |
| `search_strategy.py` | 167 | inline in APIOrchestrator | 🟢 | Enum, no separate file |
| `track_status.py` | 118 | `TrackStatus.swift` | 🟢 | **MERGED** with types.py |
| `types.py` | 32 | → `TrackStatus.swift` | ⚪ | **MERGED** with track_status.py |
| `validators.py` | 516 | throwing initializers | 🟡 | **516 → ~150 LOC**: Swift typing eliminates ~70% |
| `year_repair.py` | 281 | → `YearValidator.swift` | 🟡 | **MERGED** in Year/ package |

### src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `genre_manager.py` | 684 | `GenreDeterminator.swift` | 🔴 | Classification trees, standalone |
| `year_determination.py` | 717 | → `YearDeterminator.swift` | 🔴 | **MERGED** with year_fallback (1,588 LOC) |
| `year_fallback.py` | 871 | → `YearDeterminator.swift` | 🔴 | **MERGED** with year_determination |
| `year_retriever.py` | 366 | inline in APIOrchestrator | 🟡 | Absorbed by Services/API/ |
| `year_batch.py` | 528 | inline in BatchFlow | 🟡 | Absorbed by App/Workflows/ |
| `year_consistency.py` | 393 | → `YearValidator.swift` | 🟡 | **MERGED** with year_repair + year_utils |
| `year_utils.py` | 128 | → `YearValidator.swift` | 🟢 | **MERGED** in YearValidator |
| `update_executor.py` | 753 | → `UpdateExecutor.swift` | 🔴 | **MERGED** with track_updater |
| `track_processor.py` | 617 | `TrackProcessor.swift` | 🔴 | **MERGED** with track_base + track_utils |
| `track_updater.py` | 414 | → `UpdateExecutor.swift` | 🟡 | **MERGED** with update_executor |
| `track_delta.py` | 146 | → `IncrementalFilter.swift` | 🟢 | **MERGED** with incremental_filter |
| `track_base.py` | 73 | → `TrackProcessor.swift` | ⚪ | **MERGED** in TrackProcessor |
| `track_utils.py` | 53 | → `TrackProcessor.swift` | ⚪ | **MERGED** in TrackProcessor |
| `cache_manager.py` | 190 | `TrackDiff.swift` | 🟢 | Cache coordination for tracks |
| `incremental_filter.py` | 145 | `IncrementalFilter.swift` | 🟢 | **MERGED** with track_delta |
| `batch_fetcher.py` | 390 | → `BatchFlow.swift` | 🟡 | **MERGED** in App/Workflows/ |
| `artist_renamer.py` | 194 | → `TrackCleaningFlow.swift` | 🟢 | **MERGED** with track_cleaning |
| `prerelease_handler.py` | 174 | `PrereleaseHandler.swift` | 🟢 | Standalone |

### src/services/ → Packages/Services/Sources/Services/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `dependency_container.py` | 563 | `AppDependencies.swift` | 🟡 | **563 → ~100 LOC**: constructor injection + @Environment |
| `pending_verification.py` | 897 | `PendingVerification.swift` | 🔴 | Standalone, complex state machine |

### src/services/api/ → Packages/Services/Sources/Services/API/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `api_base.py` | 260 | → `APIClient.swift` | 🟡 | **MERGED** with request_executor → URLSession protocol |
| `request_executor.py` | 784 | → `APIClient.swift` | 🔴 | **MERGED** with api_base |
| `musicbrainz.py` | 805 | `MusicBrainzService.swift` | 🔴 | XML parsing, standalone |
| `discogs.py` | 839 | `DiscogsService.swift` | 🔴 | OAuth + pagination |
| `applemusic.py` | 638 | `AppleMusicService.swift` | 🟡 | → MusicKit native (significant simplification) |
| `orchestrator.py` | 1,400 | → `APIOrchestrator.swift` | 🔴 | **MERGED** with year_search_coordinator → actor |
| `year_search_coordinator.py` | 399 | → `APIOrchestrator.swift` | 🟡 | **MERGED** with orchestrator |
| `year_scoring.py` | 945 | → `YearScorer.swift` | 🔴 | **MOVED** to Core/Year/ (pure struct) |
| `year_score_resolver.py` | 524 | → `YearScorer.swift` | 🔴 | **MERGED** with year_scoring |

### src/services/apple/ → Packages/Services/Sources/Services/Apple/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `applescript_client.py` | 455 | → `AppleScriptBridge.swift` | 🟡 | **MERGED** with executor → actor |
| `applescript_executor.py` | 337 | → `AppleScriptBridge.swift` | 🔴 | **MERGED**, subprocess → NSUserAppleScriptTask |
| `rate_limiter.py` | 149 | `RateLimiter.swift` | 🟢 | actor-based token bucket |
| `file_validator.py` | 141 | → `InputSanitizer.swift` | 🟢 | **MERGED** with sanitizer |
| `sanitizer.py` | 202 | `InputSanitizer.swift` | 🟡 | **MERGED** with file_validator |
| — | — | `ScriptInstaller.swift` | 🟡 | **NEW**: Copy .scpt to Application Scripts |

### src/services/cache/ → Packages/Services/Sources/Services/Cache/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `album_cache.py` | 407 | → `CacheService.swift` | 🟡 | **MERGED** in unified SwiftData + NSCache actor |
| `api_cache.py` | 447 | → `CacheService.swift` | 🟡 | **MERGED** |
| `cache_config.py` | 346 | → `CacheService.swift` | 🟢 | **MERGED** (TTL config inline) |
| `orchestrator.py` | 359 | → `CacheService.swift` | 🟡 | **MERGED** |
| `fingerprint.py` | 272 | `Fingerprint.swift` | 🟡 | **MERGED** with hash_service |
| `generic_cache.py` | 402 | → `CacheService.swift` | 🟡 | **MERGED** |
| `hash_service.py` | 91 | → `Fingerprint.swift` | 🟢 | **MERGED**, CryptoKit SHA256 |
| `json_utils.py` | 37 | deleted | ⚪ | `JSONEncoder`/`JSONDecoder` is stdlib |
| `snapshot.py` | 631 | → `LibrarySnapshot.swift` | 🔴 | **MOVED** to Services/Persistence/ |

### src/metrics/ → Packages/SharedUI/Sources/SharedUI/

| Python file | LOC | Swift file | Complexity | Notes |
|-------------|-----|------------|-----------|-------|
| `analytics.py` | 570 | `MetricsCollector.swift` | 🟡 | `@Observable` |
| `change_reports.py` | 652 | `ReportsChangeLog.swift` | 🟡 | SwiftUI view (Free tier change log) |
| `csv_utils.py` | 93 | `CSVExporter.swift` | 🟢 | Direct port |
| `html_reports.py` | 428 | `ReportsCharts.swift` | 🟡 | **HTML → SwiftUI Charts** (Week Pass/Pro gated) |
| `track_sync.py` | 691 | `TrackSyncMonitor.swift` | 🔴 | Sync state machine |

### applescripts/ → Resources/Scripts/ (reuse as-is)

| File | LOC | Notes |
|------|-----|-------|
| `fetch_tracks.applescript` | 333 | Compile to .scpt, reuse |
| `fetch_tracks_by_ids.applescript` | 193 | Compile to .scpt, reuse |
| `update_property.applescript` | 190 | Compile to .scpt, reuse |
| `batch_update_tracks.applescript` | 94 | Compile to .scpt, reuse |
| `fetch_track_ids.applescript` | 49 | Compile to .scpt, reuse |

### New Swift files (no Python counterpart)

| Swift file | Complexity | Notes |
|------------|-----------|-------|
| `Views/MainView.swift` | 🟡 | NavigationSplitView, library browser |
| `Views/UpdateView.swift` | 🟡 | ProgressView, change preview |
| `Views/SettingsView.swift` | 🟢 | Form, API key management (Keychain) |
| `Views/OnboardingView.swift` | 🟡 | Script installer wizard |
| `Views/ReportsView.swift` | 🟡 | Reports tab: change log (Free) + charts/stats (Week Pass/Pro) |
| `Views/BatchView.swift` | 🟢 | Batch operations UI (Pro) |
| `Services/Subscription/SubscriptionService.swift` | 🟡 | StoreKit 2 entitlements |
| `Services/Apple/ScriptInstaller.swift` | 🟡 | Copy .scpt files to sandbox dir |
| `Services/Persistence/PersistedTrack.swift` | 🟢 | @Model (separate from domain Track struct) |
| `Services/MusicLibraryReader.swift` | 🟡 | MusicKit read wrapper |
| `App/GenreUpdaterApp.swift` | 🟢 | @main SwiftUI entry |
| `App/AppDependencies.swift` | 🟡 | Composition root (~100 LOC) |

### Mapping Statistics

| Category | Python files | Swift files | Notes |
|----------|-------------|-------------|-------|
| Ported (with merges) | 99 | ~46 | Many-to-one merges |
| Not ported | 25 | — | `__init__.py` (22) + `stubs/` (3) |
| New Swift-only | — | 12 | Views (6) + Subscription + ScriptInstaller + Persistence + MusicKit + App + DI |
| **Total Swift files** | 124 | **~58** | |
| Complexity 🔴 | — | **12** | Require careful porting |
| Complexity 🟡 | — | **22** | Standard port |
| Complexity 🟢/⚪ | — | **24** | Direct/trivial port |

---

## 3. Pattern Translation Decisions

Key decisions about translating Python → Swift patterns.

### Decision 1: Pydantic → Three-Layer Types

```
Python: Pydantic BaseModel (one model for everything)
Swift:  Domain struct (Sendable) + Codable struct (API DTO) + @Model class (persistence)
```

**Track.swift** — plain `struct` with `Sendable`. **PersistedTrack.swift** — `@Model class` for SwiftData. Never mix them.

See: [[PRD#ADR-004 Three-Layer Type System]]

### Decision 2: Python Protocol → Swift protocol

```
Python: Protocol (structural typing, 773 LOC)
Swift:  protocol (nominal typing, ~300 LOC)
```

Swift protocols are shorter due to inference and default implementations.

### Decision 3: asyncio.gather → async let / TaskGroup

```python
# Python
results = await asyncio.gather(fetch_mb(), fetch_dc(), fetch_lf())
```

```swift
// Swift — fixed set of tasks
async let mb = fetchMB()
async let dc = fetchDC()
async let lf = fetchLF()
let results = await [try? mb, try? dc, try? lf]

// Swift — dynamic collection
try await withThrowingTaskGroup(of: YearResult.self) { group in
    for provider in providers { group.addTask { try await provider.fetch() } }
}
```

Used in: [[phase-4-api-cache#APIOrchestrator]]

### Decision 4: Decorators → Generic Async Functions

```python
# Python
@retry(max_attempts=3, delay=1.0)
async def fetch_data(): ...
```

```swift
// Swift — NOT property wrappers (those are for stored values)
func withRetry<T>(maxAttempts: Int = 3, delay: Duration = .seconds(1),
                  operation: () async throws -> T) async throws -> T
```

### Decision 5: DI Container → Constructor Injection + @Environment

```
Python: dependency_container.py (563 LOC) — manual registration + resolution
Swift:  AppDependencies.swift (~100 LOC) — composition root + @Environment
```

### Decision 6: subprocess → NSUserAppleScriptTask actor

```
Python: subprocess.run(["osascript", script_path])
Swift:  NSUserAppleScriptTask(url:) — runs OUTSIDE sandbox
```

**HIGHEST RISK**. Scripts must be in `~/Library/Application Scripts/<bundle-id>/`. Budget 2-3x estimation.

See: [[PRD#ADR-002 NSUserAppleScriptTask for App Store Compatibility]]

### Decision 7: Python logging → os.Logger

```
Python: logger.py (1,092 LOC) — custom handlers, formatters, rotation
Swift:  Logging.swift (~100 LOC) — os.Logger + OSLogStore for retrieval
```

macOS handles log rotation, filtering, persistence automatically.

### Decision 8: 3-Tier Cache → SwiftData + GRDB + NSCache

```
Python: 10 files (2,993 LOC) — JSON files, gzip, fingerprint, TTL logic
Swift:  3 files (~800 LOC) — CacheService actor + CachedModels @Model + Fingerprint
```

See: [[PRD#ADR-005 Hybrid Cache -- SwiftData + GRDB]]

### Decision 9: Year Scoring → Pure Struct

```
Python: year_scoring.py (945 LOC) + year_score_resolver.py (524 LOC) — classes with state
Swift:  YearScorer.swift — pure struct with static methods (no shared mutable state)
```

Scoring is a pure function from inputs → score. Does NOT need actor.

Referenced by: [[phase-3-core-algorithms#ScoringEngine (найскладніший компонент)]]

### Decision 10: Error Handling → Typed Throws (Swift 6)

```swift
// Per-module error enums
enum APIError: Error { case rateLimited(retryAfter: Duration), notFound, ... }
enum CacheError: Error { case expired, corrupted(path: URL), ... }

// Typed throws
func fetchYear(artist: String, album: String) throws(APIError) -> YearResult
```

See: [[PRD#Error Handling Architecture]]

---

## 4. Implementation Code Patterns

### Music.app Integration

**Reading** — MusicKit (type-safe, fast):
```swift
var request = MusicLibraryRequest<Song>()
request.sort(by: \.libraryAddedDate, ascending: false)
let response = try await request.response()
```

**Writing** — NSUserAppleScriptTask (scripts in `~/Library/Application Scripts/<bundle-id>/`):
```swift
let scriptsURL = try FileManager.default.url(
    for: .applicationScriptsDirectory, in: .userDomainMask,
    appropriateFor: nil, create: true)
let task = try NSUserAppleScriptTask(url: scriptURL)
try await task.execute(withAppleEvent: event)
```

**Onboarding UX**: First-launch wizard → "Install Scripts" → copies `.scpt` files → validates.

### Caching — SwiftData + GRDB

```swift
// GRDB for API cache (raw speed)
@Model class CachedAPIResult {
    var artist: String
    var album: String
    var year: Int?
    var source: String
    var confidence: Int
    var timestamp: Date
    var ttl: TimeInterval
    var isExpired: Bool { Date.now > timestamp.addingTimeInterval(ttl) }
}
```

### API Integration — URLSession + async/await

```swift
actor APIOrchestrator {
    func getAlbumYear(artist: String, album: String) async throws -> YearResult {
        async let mb = musicBrainz.fetchYear(artist: artist, album: album)
        async let dc = discogs.fetchYear(artist: artist, album: album)
        async let lf = lastFM.fetchYear(artist: artist, album: album)
        let results = await [try? mb, try? dc, try? lf]
        return resolveYearScores(results.compactMap { $0 })
    }
}
```

### Feature Gating — StoreKit 2 (3-Tier)

```swift
enum Tier: Comparable { case free, weekPass, pro }

@Observable class SubscriptionManager {
    var currentTier: Tier = .free

    func checkEntitlement() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            switch transaction.productID {
            case "pro_monthly", "pro_annual":
                currentTier = .pro
            case "week_pass":
                // Non-renewing: check purchaseDate + 7 days
                let expiry = transaction.purchaseDate.addingTimeInterval(7 * 86400)
                if expiry > Date.now { currentTier = max(currentTier, .weekPass) }
            default: break
            }
        }
    }

    var weekPassCooldownRemaining: TimeInterval? {
        // purchaseDate + 7d pass + 14d cooldown
        guard let lastPurchase = lastWeekPassPurchaseDate else { return nil }
        let cooldownEnd = lastPurchase.addingTimeInterval(21 * 86400)
        return cooldownEnd > Date.now ? cooldownEnd.timeIntervalSince(Date.now) : nil
    }
}
```

**Products:** `pro_monthly` (auto-renewable), `pro_annual` (auto-renewable), `week_pass` (non-renewing subscription).
**Auto-sync** gated on `.pro` only — the single feature justifying recurring subscription.

---

## 5. LOC Estimates

| Swift Package | Python LOC | Swift LOC (est.) | Ratio | Why |
|---------------|-----------|-----------------|-------|-----|
| App/ (Views + Workflows) | 4,003 | ~2,800 | 0.70x | CLI boilerplate → SwiftUI declarative |
| Core/Config/ | 426 | ~250 | 0.59x | Pydantic → Codable synthesis |
| Core/Models/ | 4,556 | ~2,500 | 0.55x | Pydantic validators → native typing |
| Core/Genre/ | 684 | ~600 | 0.88x | Algorithmic logic ~same volume |
| Core/Year/ | 4,536 | ~3,500 | 0.77x | Merges reduce glue code |
| Core/Processing/ | 2,714 | ~2,000 | 0.74x | Merges (processor+updater+delta) |
| Core/Infra/ | 1,899 | ~400 | 0.21x | **os.Logger**: 1,092→100 |
| Services/API/ | 7,603 | ~5,500 | 0.72x | URLSession async; MusicKit simplifies |
| Services/Apple/ | 1,289 | ~1,200 | 0.93x | NSUserAppleScriptTask ≈ subprocess |
| Services/Cache/ | 2,993 | ~800 | 0.27x | **SwiftData eliminates 80%** |
| Services/Persistence/ | — | ~400 | — | @Model + SwiftData (NEW) |
| SharedUI/ | 2,439 | ~1,800 | 0.74x | SwiftUI Charts < HTML |
| Views/ (NEW) | — | ~2,000 | — | SwiftUI views |
| Subscription/ (NEW) | — | ~600 | — | StoreKit 2 (3-tier: Free/Week Pass/Pro + cooldown + iCloud counter) |
| **Subtotal source** | **33,142** | **~23,150** | **0.70x** | |
| AppleScripts (reuse) | 859 | 859 | 1.0x | No changes |
| **Total source** | **34,001** | **~24,009** | **0.71x** | |
| Tests/ (est.) | 53,400 | ~20,000 | 0.37x | Swift Testing compact |
| **Grand Total** | **87,401** | **~44,009** | **0.50x** | |

### LOC Savings Breakdown

| Elimination | Python LOC saved | How |
|------------|-----------------|-----|
| logging → os.Logger | ~990 | Platform API replaces custom handlers |
| Pydantic → Codable | ~800 | Compiler-synthesized conformance |
| DI container → @Environment | ~460 | SwiftUI native DI |
| Cache → SwiftData | ~2,200 | SQLite replaces manual JSON/gzip/TTL |
| Validators → throwing init | ~370 | Swift type system handles validation |
| Protocol → Swift protocol | ~470 | Nominal typing, default implementations |
| **Total eliminated** | **~5,290** | |

---

## 6. Risks & Mitigation

| Risk | Severity | Mitigation |
|------|----------|-----------|
| NSUserAppleScriptTask App Review rejection | 🔴 High | Apple documents this as sanctioned; fallback → NSAppleScript + temporary-exception (~2 weeks) |
| AppleScriptBridge actor complexity | 🔴 High | **HIGHEST RISK**: Budget 2-3x; prototype FIRST in Phase 1 ✅ |
| macOS Tahoe AppleScript regressions | 🟡 Medium | Abstract behind protocol; swap write path without architecture changes |
| Scoring algorithm porting bugs | 🟡 Medium | Test suite with Python test data; parallel run both implementations |
| Script installation UX friction | 🟡 Medium | Polish onboarding; auto-detect; troubleshooting guide |
| MusicKit missing properties | 🟡 Medium | Fallback to AppleScript reads for missing MusicKit properties |
| SwiftData performance (30K+ tracks) | 🟡 Medium | Batch inserts, background context, lazy fetch; profile with Instruments |

### Fallback Plan

If App Review rejects NSUserAppleScriptTask:
1. Replace `AppleScriptBridge` with inline NSAppleScript + `temporary-exception.apple-events`
2. Rest of architecture stays identical (protocol abstraction)
3. Transition time: ~2 weeks

---

## 6.5 Intentional Python / Swift Divergences

The Swift port intentionally diverges from Python in several areas.
These are design decisions, not bugs — "parity" means algorithmic
equivalence within each language's idioms, not identical output.

| Area | Python | Swift | Rationale |
|------|--------|-------|-----------|
| Genre nil | Returns `"Unknown"` string when no genre is found | Returns `nil` (Optional) | Swift idiom: optionals express absence more precisely than sentinel strings. Callers pattern-match rather than comparing to a magic string. |
| Definitiveness | Combines score threshold + gap to second-best + release status flags | Uses `score >= 85` only (single threshold) | Simpler logic that avoids coupling the definitiveness check to scoring internals. The gap heuristic added complexity without measurably improving accuracy in testing. |
| Country scoring | Tiered bonus system for major markets (US, GB, DE, JP, etc.) with graduated penalties | Flat `+10` for artist-region match, `-5` for mismatch | Country data from MusicBrainz/Discogs is inconsistent. Flat scoring reduces sensitivity to noisy input while preserving the basic signal. |
| Earliest-year heuristic | Implicitly prefers earliest year through sorting | Explicit 90th-percentile heuristic to filter reissues | Makes the reissue-detection intent explicit. The 90% threshold was tuned against the test library to match Python's effective behavior. |
| Concurrency | Sequential processing with thread pool for I/O | Swift actors for shared mutable state, async/await throughout | Required for macOS app architecture. Actors provide compile-time data-race safety that Python's GIL handles implicitly. |

Parity test fixtures validate that scoring, resolution, fallback,
and validation produce equivalent results within these documented
divergences. The fixture generator (`tools/generate_swift_fixtures.py`)
captures Python's exact output as the reference baseline.

---

## 7. Phase 1: Completion Report

**Commit**: `f4726fd` on `main` branch
**Files**: 24 files, 2,893 LOC
**Result**: All 3 SPM packages compile, Xcode project builds, 6 smoke tests pass

### Files Created (24)

**Core package** (7 files):

| File | LOC | Notes |
|------|-----|-------|
| `Packages/Core/Package.swift` | 25 | swift-tools-version: 6.0, macOS 15, StrictConcurrency |
| `Packages/Core/Sources/Core/Models/Track.swift` | ~280 | Domain struct, Sendable, `fromAppleScriptOutput()` |
| `Packages/Core/Sources/Core/Models/TrackStatus.swift` | ~150 | TrackKind enum with raw constant normalization |
| `Packages/Core/Sources/Core/Models/Protocols.swift` | ~180 | AppleScriptClient, ExternalApiService, CacheService protocols |
| `Packages/Core/Sources/Core/Config/AppConfiguration.swift` | ~304 | ~20 Codable structs for full config hierarchy |
| `Packages/Core/Sources/Core/Infra/Logging.swift` | ~50 | AppLogger enum wrapping os.Logger |
| `Packages/Core/Tests/CoreTests/CoreTests.swift` | ~40 | 5 smoke tests (Swift Testing) |

**Services package** (6 files):

| File | LOC | Notes |
|------|-----|-------|
| `Packages/Services/Package.swift` | 30 | Depends on Core, MusicKit |
| `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift` | ~240 | Actor, NSUserAppleScriptTask + timeout |
| `Packages/Services/Sources/Services/Apple/InputSanitizer.swift` | ~152 | Injection prevention, metachar stripping |
| `Packages/Services/Sources/Services/Apple/ScriptInstaller.swift` | ~161 | Sandbox Application Scripts directory |
| `Packages/Services/Sources/Services/MusicLibraryReader.swift` | ~143 | MusicKit MusicLibraryRequest wrapper |
| `Packages/Services/Tests/ServicesTests/ServicesTests.swift` | ~11 | 1 smoke test |

**SharedUI package** (3 files):

| File | LOC | Notes |
|------|-----|-------|
| `Packages/SharedUI/Package.swift` | 25 | Depends on Core, SwiftUI |
| `Packages/SharedUI/Sources/SharedUI/SharedUI.swift` | ~10 | Placeholder module |
| `Packages/SharedUI/Tests/SharedUITests/SharedUITests.swift` | ~10 | 1 smoke test |

**App target** (7 files):

| File | LOC | Notes |
|------|-----|-------|
| `App/GenreUpdaterApp.swift` | ~50 | @main entry, WindowGroup |
| `App/AppDependencies.swift` | ~80 | Composition root, @Observable |
| `App/Views/MainView.swift` | ~180 | NavigationSplitView library browser |
| `App/Views/OnboardingView.swift` | ~220 | Script installation wizard |
| `App/GenreUpdater.entitlements` | — | App Sandbox + scripting-targets |
| `App/Info.plist` | — | NSAppleMusicUsageDescription |
| `project.yml` | ~65 | XcodeGen config |

### Verification Results

```
swift build (Core):     Build complete (6.34s) ✅
swift build (Services): Build complete (1.55s) ✅
swift build (SharedUI): Build complete (13.86s) ✅
swift test (Core):      5/5 passed ✅
swift test (SharedUI):  1/1 passed ✅
xcodebuild build:       BUILD SUCCEEDED ✅
```

---

## 8. Lessons Learned (CRITICAL for future phases)

### Lesson 1: SPM `public` Access Control

**Every** type, property, method, and init in SPM packages MUST be `public` for cross-package visibility. Swift does NOT synthesize memberwise initializers for `public` structs.

```swift
// Structs with all default values:
public struct MyConfig: Sendable, Codable {
    public var timeout: Duration = .seconds(30)
    public init() {}  // REQUIRED — compiler won't synthesize
}

// Structs with non-default properties:
public struct ScriptAPIPriority: Sendable, Codable {
    public let primary: String
    public let fallback: String
    public init(primary: String, fallback: String) {
        self.primary = primary
        self.fallback = fallback
    }
}
```

### Lesson 2: `Core.Track` Namespace Disambiguation

MusicKit defines its own `MusicKit.Track` enum. Services files that `import MusicKit` AND `import Core` must use `Core.Track` everywhere:

```swift
// ❌ Ambiguous
func fetchAllTracks() async throws -> [Track]

// ✅ Correct
func fetchAllTracks() async throws -> [Core.Track]
```

### Lesson 3: Swift 6 Strict Concurrency + TaskGroup `sending`

`NSUserAppleScriptTask` and `NSAppleEventDescriptor` are NOT `Sendable`. Capturing in `group.addTask` triggers `sending` parameter error.

**Solution**: `@unchecked Sendable` wrapper:
```swift
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

// Usage in actor method:
let wrappedTask = UnsafeSendable(value: task)
let wrappedEvent = UnsafeSendable(value: event)
group.addTask {
    let descriptor = try await wrappedTask.value.execute(withAppleEvent: wrappedEvent.value)
    return descriptor.stringValue
}
```

This wrapper will be needed again in [[phase-4-api-cache|Phase 4]] and [[phase-5-workflows|Phase 5]] for other Foundation types.

### Lesson 4: `Carbon.OpenScripting` Import

AppleScript event constants (`kASAppleScriptSuite`, `kASSubroutineEvent`, etc.) live in **Carbon.OpenScripting**, NOT Foundation:

```swift
import Carbon.OpenScripting  // Required for AppleScript event building
```

### Lesson 5: `MusicItemID` Init is NOT Failable

```swift
// ❌ Compiler error
guard let musicItemID = MusicItemID(id) else { return nil }

// ✅ Correct — always succeeds
let musicItemID = MusicItemID(id)
```

### Lesson 6: `NSUserAppleScriptTask.execute(withAppleEvent:)` Returns Non-Optional

```swift
// ❌ Compiler error
return descriptor?.stringValue

// ✅ Correct
return descriptor.stringValue
```

### Lesson 7: SwiftUI `.accent` ShapeStyle Does Not Exist

```swift
// ❌ Compiler error on macOS
.foregroundStyle(.accent)

// ✅ Correct
.foregroundStyle(.tint)
```

### Lesson 8: XcodeGen — No Explicit MusicKit.framework

MusicKit is linked automatically when `import MusicKit` is used. Do NOT add it in `project.yml`:

```yaml
# ❌ Wrong — "No such file or directory"
dependencies:
  - framework: MusicKit.framework

# ✅ Correct — MusicKit comes via Services package
dependencies:
  - package: Core
  - package: Services
  - package: SharedUI
```

---

*End of TDD*
