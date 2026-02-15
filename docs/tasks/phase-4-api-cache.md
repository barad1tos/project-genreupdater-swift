---
phase: 4
title: "API Clients + Cache"
status: planned
priority: high
depends_on:
  - "Phase 2 (GRDB setup)"
  - "Phase 3 (algorithms need API data)"
---
> Parent: [[PRD]]

**Related:** [[phase-2-core-models|Phase 2: Core Models]] | [[phase-3-core-algorithms|Phase 3: Core Algorithms]] | [[phase-5-workflows|Phase 5: Workflows]]
**Technical ref:** [[TDD#src/services/api/ → Packages/Services/Sources/Services/API/]] | [[TDD#Decision 3 asyncio.gather → async let / TaskGroup]] | [[TDD#Decision 8 3-Tier Cache → SwiftData + GRDB + NSCache]]

# Phase 4: API Clients + Cache

## Context

Інтеграція з зовнішніми API (MusicBrainz, Discogs, Apple Music Search) для отримання метаданих. Кешування відповідей в GRDB для зменшення API calls. Rate limiting для дотримання лімітів API.

Можна scaffold API client stubs паралельно з Phase 3.

## Deliverables

### MusicBrainzClient
> **TDD ref:** [[TDD#src/services/api/ → Packages/Services/Sources/Services/API/]] (`musicbrainz.py` 805 LOC → `MusicBrainzService.swift` 🔴, XML parsing) | [[TDD#API Integration — URLSession + async/await]] (async/await pattern)

- [ ] Створити `Packages/Services/Sources/Services/API/MusicBrainzClient.swift`
- [ ] Sendable struct + URLSession
- [ ] Release group search (artist + album)
- [ ] Release details (year, genres/tags)
- [ ] Artist lookup (activity period)
- [ ] DTO types: `MusicBrainzRelease`, `MusicBrainzReleaseGroup`, `MusicBrainzArtist`
- [ ] Rate limiting: max 1 req/sec (MusicBrainz policy)
- [ ] Error handling: 503 retry, 400 bad request, network errors
- [ ] Integration tests з live API (rate-limited)

### DiscogsClient
> **TDD ref:** [[TDD#src/services/api/ → Packages/Services/Sources/Services/API/]] (`discogs.py` 839 LOC → `DiscogsService.swift` 🔴, OAuth + pagination) | [[TDD#Decision 10 Error Handling → Typed Throws (Swift 6)]] (per-module `APIError` enum)

- [ ] Створити `Packages/Services/Sources/Services/API/DiscogsClient.swift`
- [ ] Sendable struct + URLSession
- [ ] Master release search
- [ ] Release details (year, styles/genres)
- [ ] Artist lookup
- [ ] DTO types: `DiscogsRelease`, `DiscogsMaster`, `DiscogsArtist`
- [ ] Auth: Personal access token з Keychain
- [ ] Rate limiting: 60 req/min (Discogs policy)
- [ ] Integration tests

### AppleMusicSearchClient
> **TDD ref:** [[TDD#src/services/api/ → Packages/Services/Sources/Services/API/]] (`applemusic.py` 638 LOC → MusicKit native, значне спрощення) | [[TDD#Music.app Integration]] (MusicKit `CatalogSearchRequest`)

- [ ] Створити `Packages/Services/Sources/Services/API/AppleMusicSearchClient.swift`
- [ ] Sendable struct + MusicKit CatalogSearchRequest
- [ ] Catalog search (artist + album + track)
- [ ] Genre extraction з Apple Music catalog
- [ ] DTO type: `AppleMusicSearchResult`
- [ ] Integration tests

### APIOrchestrator
> **TDD ref:** [[TDD#Decision 3 asyncio.gather → async let / TaskGroup]] (паралельні запити: `async let mb, dc, lf`) | [[TDD#API Integration — URLSession + async/await]] (actor code pattern) | [[TDD#src/services/api/ → Packages/Services/Sources/Services/API/]] (`orchestrator.py` + `year_search_coordinator.py` merge → 1,799 LOC)

- [ ] Створити `Packages/Services/Sources/Services/API/APIOrchestrator.swift`
- [ ] Actor для координації паралельних API calls
- [ ] Multi-source query: запит до всіх API одночасно
- [ ] Aggregation results від різних sources
- [ ] Timeout handling per source
- [ ] Fallback: якщо один API недоступний, продовжити з іншими
- [ ] Unit tests: orchestration logic, timeout, fallback

### GRDBCacheService (повна реалізація)
> **TDD ref:** [[TDD#Decision 8 3-Tier Cache → SwiftData + GRDB + NSCache]] (чому 3 рівні: SwiftData для UI, GRDB для API speed, NSCache для hot path) | [[TDD#src/services/cache/ → Packages/Services/Sources/Services/Cache/]] (10 Python files 2,993 LOC → 3 Swift files ~800 LOC)

- [ ] Розширити stub з Phase 2 до повної реалізації
- [ ] get/set/delete/clear operations
- [ ] TTL-based expiry (configurable per cache type)
- [ ] Cache policy implementation:
  - [ ] Album year (positive): 30 days
  - [ ] Album year (negative): 30 days
  - [ ] API response (default): 15 minutes
- [ ] Bulk operations для batch processing
- [ ] Cache statistics (hit/miss ratio)
- [ ] Unit tests: CRUD, expiry, bulk, statistics

### NetworkReachability
> **TDD ref:** [[TDD#Risks & Mitigation]] (network unavailability = 🟡 Medium risk, "Queue requests for retry on reconnect")

- [ ] Створити `Packages/Services/Sources/Services/Network/NetworkReachability.swift`
- [ ] Detect internet availability (NWPathMonitor)
- [ ] Show offline indicator в UI
- [ ] Queue requests для повторної спроби при reconnect
- [ ] Unit tests

### Rate Limiter Implementations
> **TDD ref:** [[TDD#Decision 4 Decorators → Generic Async Functions]] (Python `@retry` → Swift `withRetry()`) | [[TDD#src/services/apple/ → Packages/Services/Sources/Services/Apple/]] (`rate_limiter.py` 149 LOC → actor-based token bucket)

- [ ] Реалізувати `RateLimiter` протокол для кожного API
- [ ] Token bucket або sliding window algorithm
- [ ] Per-API конфігурація (MusicBrainz: 1/sec, Discogs: 60/min)
- [ ] Unit tests: rate enforcement, burst handling

## Files (~8)

| File | Description |
|------|-------------|
| `Services/API/MusicBrainzClient.swift` | MusicBrainz API |
| `Services/API/DiscogsClient.swift` | Discogs API |
| `Services/API/AppleMusicSearchClient.swift` | Apple Music catalog |
| `Services/API/APIOrchestrator.swift` | Multi-source coordination |
| `Services/Cache/GRDBCacheService.swift` | Full cache implementation |
| `Services/Network/NetworkReachability.swift` | Internet detection |
| `Services/API/RateLimiterImpl.swift` | Rate limiting |
| `Services/Cache/VersionedSchema.swift` | DB migrations (extend) |

## Acceptance Criteria

- [ ] API fetch → score → cache cycle працює end-to-end
- [ ] Cache hit/miss/expiry поведінка verified
- [ ] Rate limiting запобігає API throttling
- [ ] Network unavailability handled gracefully (offline mode)
- [ ] Всі API clients мають integration tests
- [ ] `swift build` + `swift test` проходять

## Dependencies

- Phase 2 (GRDB schema, CacheService protocol)
- Phase 3 (scoring engine needs API data)
- Discogs API token (user provides during onboarding)

## Notes

- MusicBrainz не потребує автентифікації — найлегший для початку
- Discogs потребує Personal Access Token → зберігається в Keychain
- Apple Music Search використовує MusicKit → автоматична авторизація
- Scaffold API stubs можна починати паралельно з Phase 3
