# Architecture

**Analysis Date:** 2026-02-22

## Pattern Overview

**Overall:** Layered SPM Package Architecture with Actor-based Concurrency

**Key Characteristics:**
- Three-tier SPM package dependency graph: `App → Services → Core` (enforced at compile time)
- `Core` contains zero external dependencies — pure domain logic, algorithms, and protocols
- `Services` wraps all external concerns (MusicKit, AppleScript, GRDB, SwiftData, StoreKit)
- `App` is the composition root — wires dependencies, owns SwiftUI views and view models
- Swift actors provide serial execution for all shared mutable state
- Strict Concurrency (`enableExperimentalFeature("StrictConcurrency")`) enforced in all packages
- macOS Swift Tools 6.0 throughout; minimum deployment target macOS 15

## Layers

**Core (Pure Domain):**
- Purpose: Business logic, algorithms, domain models, and service protocols. No I/O.
- Location: `Packages/Core/Sources/Core/`
- Contains: `Track` struct, protocols, year/genre algorithms, configuration, normalization utilities
- Depends on: Foundation, OSLog only (zero third-party dependencies)
- Used by: Services, SharedUI, App

**Services (External World):**
- Purpose: All side effects — reading Music library, writing via AppleScript, API calls, persistence
- Location: `Packages/Services/Sources/Services/`
- Contains: `AppleScriptBridge` actor, `MusicLibraryReader` actor, `APIOrchestrator` actor, GRDB cache, SwiftData stores, workflow coordinators, subscription service
- Depends on: Core, GRDB 7.x (third-party), MusicKit, SwiftData, StoreKit 2
- Used by: App

**SharedUI (Design System):**
- Purpose: Reusable SwiftUI components and design tokens shared across views
- Location: `Packages/SharedUI/Sources/SharedUI/`
- Contains: `TrackRow`, `TrackDetailView`, `ConfidenceBadge`, `ProgressRing`, `TierBadge`, `PaywallOverlay`, `EmptyStateView`, `ReportsChangeLog`, `ReportsCharts`, design tokens (`Spacing`, `Radius`, `AppFont`, `Ayu` color palette)
- Depends on: Core only (no Services — components receive data via parameters/bindings)
- Used by: App

**App (Composition Root + UI):**
- Purpose: Entry point, DI container, view hierarchy, view models, keyboard commands
- Location: `App/`
- Contains: `GenreUpdaterApp` (@main), `AppDependencies` (DI container), views, view models
- Depends on: Core, Services, SharedUI

## Data Flow

**Library Read Flow:**

1. `MusicLibraryReader` (actor) calls MusicKit API on launch
2. MusicKit `Song` objects are mapped to `Core.Track` structs (Sendable value types)
3. `SwiftDataTrackStore` actor persists/updates `PersistedTrack` `@Model` objects
4. `MainView` holds `[Track]` in `@State` — passed to child views and view models

**Update Flow (Single Track):**

1. User triggers update from `UpdateView` → `UpdateViewModel` (@Observable @MainActor)
2. `UpdateViewModel` calls `UpdateCoordinator` actor with selected tracks
3. `UpdateCoordinator` calls `GenreDeterminator` (pure struct, local analysis) for genre
4. `UpdateCoordinator` calls `APIOrchestrator` actor for year determination
5. `APIOrchestrator` fans out parallel async tasks to MusicBrainz, Discogs, Apple Music
6. `YearDeterminator` (pure struct) scores candidates → `YearResult` with confidence
7. `ChangePreviewPipeline` (pure struct) aggregates `[ProposedChange]`
8. If dry-run: proposed changes returned to UI for review
9. If confirmed: `AppleScriptBridge` actor writes each change to Music.app via `NSUserAppleScriptTask`
10. `UndoCoordinator` writes `ChangeLogEntry` to `SwiftDataChangeLogStore`

**Batch Processing Flow:**

1. `BatchProcessor` actor streams `ProgressUpdate` via `AsyncStream`
2. `CheckpointManager` persists resume state (JSON in Application Support)
3. `UpdateCoordinator.updateTrack()` called per-track within batch
4. `FeatureGate` enforces track limit for free tier at batch entry point

**Progress Reporting:**

- `ProgressUpdate` Sendable struct streams over `AsyncStream<ProgressUpdate>`
- View models observe stream on `@MainActor` and publish to `@Observable` state
- Four phases: `.fetching` → `.analyzing` → `.updating` → `.complete`

**State Management:**

- `AppDependencies`: `@Observable @MainActor` class — single source of truth for service instances
- View-local state: `@State` in SwiftUI views
- View models: `@Observable @MainActor` — bridge between Services actors and SwiftUI
- Subscriptions: `SubscriptionService` publishes tier changes; `FeatureGate` reads via closure providers

## Key Abstractions

**`Core.Track`:**
- Purpose: Primary domain model; represents one Apple Music library track
- Location: `Packages/Core/Sources/Core/Models/Track.swift`
- Pattern: Plain `struct`, `Sendable`, `Codable`, `Identifiable`, `Hashable` — freely crosses actor boundaries
- Note: Distinct from `MusicKit.Track` — always qualify as `Core.Track` in Services code

**`PersistedTrack`:**
- Purpose: SwiftData persistence model for track processing state
- Location: `Packages/Services/Sources/Services/Persistence/SwiftData/PersistedTrack.swift`
- Pattern: `@Model final class` — maps to `Core.Track` but stores `genreUpdated`, `yearUpdated` flags

**Service Protocols (in Core):**
- Purpose: Define contracts implemented by Services actors; tested via mocks in Core
- Location: `Packages/Core/Sources/Core/Models/Protocols.swift`
- Key protocols: `CacheService: Actor`, `TrackStateStore: Actor`, `ExternalAPIService: Sendable`, `AppleScriptClient: Actor`, `ChangeLogStore: Actor`, `RateLimiter: Actor`, `TrackIDMapping: Sendable`

**`AppDependencies`:**
- Purpose: Composition root and observable DI container
- Location: `App/AppDependencies.swift`
- Pattern: `@Observable @MainActor final class` injected via `.environment(dependencies)` — all services accessed through this
- Initialization order: config → scripts → bridge → reader → subscription → persistence → algorithms → workflow

**`UpdateCoordinator`:**
- Purpose: Central update orchestrator; coordinates API, script bridge, cache, undo
- Location: `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift`
- Pattern: `public actor` — all calls are async; supports single-track, batch, and dry-run modes

**`APIOrchestrator`:**
- Purpose: Fan-out parallel queries to MusicBrainz, Discogs, Apple Music; aggregate by confidence
- Location: `Packages/Services/Sources/Services/API/APIOrchestrator.swift`
- Pattern: `public actor` — each source runs in independent `withThrowingTaskGroup` child task with per-source timeout

## Entry Points

**App Entry:**
- Location: `App/GenreUpdaterApp.swift`
- Triggers: macOS app launch
- Responsibilities: Creates `AppDependencies`, calls `dependencies.initialize()` in `.task`, registers keyboard commands, manages `ScenePhase` lifecycle

**Content Router:**
- Location: `App/GenreUpdaterApp.swift` (`ContentView`)
- Triggers: `AppDependencies.appState` changes
- Responsibilities: Routes to `OnboardingView`, `MainView`, or error state based on `AppState` enum

**Main Navigation:**
- Location: `App/Views/MainView.swift`
- Triggers: App state becomes `.ready`
- Responsibilities: `NavigationSplitView` with four-item sidebar: Dashboard, Browse, Update, Reports. Keyboard shortcuts Cmd+1–4 for navigation.

## Error Handling

**Strategy:** Per-module typed error enums propagate upward; App layer displays localized descriptions.

**Error Types:**
- `AppleScriptBridgeError`: script not found, execution failed, timeout, parse error, music app not running
- `MusicLibraryError`: authorization denied/restricted, fetch failed
- `UpdateCoordinatorError`: track not editable, no changes produced, all tracks failed, write failed
- `BatchProcessorError`: feature not available, already running, not running, cancelled
- `FeatureGateError`: feature requires tier, free track limit reached
- `AppState.error(String)`: top-level app state with retry affordance

**Patterns:**
- Errors preserve chain with `throw XError.case(from: originalError)` where applicable
- Actor throws propagate cleanly across await boundaries
- View models catch and assign `errorMessage: String?` for alert presentation

## Cross-Cutting Concerns

**Logging:** `AppLogger` factory in `Packages/Core/Sources/Core/Infra/Logging.swift`. Subsystem `com.genreupdater.app`. Pre-built loggers: `.api`, `.cache`, `.genre`, `.year`, `.processing`, `.applescript`, `.sync`, `.subscription`. User data always logged with `privacy: .private`; system identifiers use `privacy: .public`.

**Validation / Input Sanitization:** `InputSanitizer` in `Packages/Services/Sources/Services/Apple/InputSanitizer.swift`. Two distinct functions — `sanitizeScriptCode()` for AppleScript fragments (strips shell metacharacters), `escapeStringValue()` for data values (escapes `"` and `\` only). NEVER apply `sanitizeScriptCode()` to track metadata.

**Feature Gating:** `FeatureGate` (`@MainActor`) enforces `Tier` (`.free`, `.weekPass`, `.pro`) against `AppFeature` enum. Free tier: 500 tracks. Checked at `BatchProcessor` entry and `LibrarySyncService`. DEBUG builds hardcode `.pro` tier.

**Concurrency:** All service types with shared mutable state are `actor`. All domain models are `Sendable`. `nonisolated(unsafe)` used only for `ISO8601DateFormatter` (documented as safe because configured-once-never-mutated). `@MainActor` on all view models and `AppDependencies`.

**AppleScript Execution:** `NSUserAppleScriptTask` via `AppleScriptBridge` actor. Scripts installed to `~/Library/Application Scripts/<bundle-id>/` during onboarding by `ScriptInstaller`. Five script files: `fetch_tracks.applescript`, `fetch_tracks_by_ids.applescript`, `fetch_track_ids.applescript`, `batch_update_tracks.applescript`, `update_property.applescript`.

**Persistence:** Dual-store — SwiftData (`PersistedTrack`, `PersistedChangeLogEntry`) for track state with `@Query` SwiftUI integration; GRDB (`DatabasePool`) for API response cache at `api_cache.db`. `ModelContainerFactory` creates SwiftData stack. Both stores initialized in `AppDependencies.initializePersistence()`.

**Subscriptions:** StoreKit 2 via `SubscriptionService`. `FeatureGate` reads tier via closure provider to avoid coupling.

---

*Architecture analysis: 2026-02-22*
