---
phase: 2A
title: Persistence Layer
status: done
priority: high
depends_on: [phase-1]
---

# Phase 2A: Persistence Layer

## Deliverables

### Core Package
- [x] `ProgressUpdate` struct with `ProcessingPhase` enum
- [x] `TrackStateStore` protocol in Protocols.swift

### Services Package — GRDB
- [x] Add GRDB 7.x dependency to Package.swift
- [x] `GRDBMigrations` — versioned schema (api_results, album_years, generic_cache)
- [x] `GRDBModels` — CachedAPIRow, AlbumYearRow, GenericCacheRow
- [x] `GRDBCacheService` actor implementing CacheService protocol

### Services Package — SwiftData
- [x] `PersistedTrack` @Model with Core.Track conversion
- [x] `SwiftDataTrackStore` @ModelActor implementing TrackStateStore protocol

### Tests
- [x] ProgressUpdateTests (8 tests)
- [x] GRDBCacheServiceTests (15 tests)
- [x] SwiftDataTrackStoreTests (9 tests)

### Quality
- [x] SwiftLint --strict: 0 violations
- [x] Core swift build: clean
- [x] Services swift build: clean
- [x] Core swift test: 18/18 pass
- [x] Services swift test: 32/32 pass

## Files

| File | Action | Package |
|------|--------|---------|
| `Core/Sources/Core/Models/ProgressUpdate.swift` | CREATE | Core |
| `Core/Sources/Core/Models/Protocols.swift` | MODIFY | Core |
| `Services/Package.swift` | MODIFY | Services |
| `Services/Sources/Services/Persistence/GRDB/GRDBMigrations.swift` | CREATE | Services |
| `Services/Sources/Services/Persistence/GRDB/GRDBModels.swift` | CREATE | Services |
| `Services/Sources/Services/Persistence/GRDB/GRDBCacheService.swift` | CREATE | Services |
| `Services/Sources/Services/Persistence/SwiftData/PersistedTrack.swift` | CREATE | Services |
| `Services/Sources/Services/Persistence/SwiftData/SwiftDataTrackStore.swift` | CREATE | Services |
| `Services/Sources/Services/Apple/AppleScriptBridge.swift` | MODIFY | Services |
| `Core/Tests/CoreTests/ProgressUpdateTests.swift` | CREATE | Core |
| `Services/Tests/ServicesTests/GRDBCacheServiceTests.swift` | CREATE | Services |
| `Services/Tests/ServicesTests/SwiftDataTrackStoreTests.swift` | CREATE | Services |

## Acceptance Criteria

- [x] GRDB 7.10.0 resolved and compiles with Swift 6 strict concurrency
- [x] All CacheService protocol methods implemented in GRDBCacheService
- [x] All TrackStateStore protocol methods implemented in SwiftDataTrackStore
- [x] TTL expiry works for generic cache, album years, and API results
- [x] Batch save handles 600+ tracks with chunked inserts
- [x] In-memory factories available for both services (testing)
- [x] Zero SwiftLint violations
- [x] All 50 tests pass
