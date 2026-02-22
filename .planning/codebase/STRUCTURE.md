# Codebase Structure

**Analysis Date:** 2026-02-22

## Directory Layout

```
GenreUpdater/
├── App/                          # Main app target (SwiftUI, @main)
│   ├── GenreUpdaterApp.swift     # App entry point, ContentView router
│   ├── AppDependencies.swift     # DI container + app state (@Observable)
│   ├── Views/                    # SwiftUI screens
│   │   ├── MainView.swift        # NavigationSplitView with 4-item sidebar
│   │   ├── DashboardView.swift   # Library stats and quick actions
│   │   ├── BrowseView.swift      # Library browser (artist/album grouping)
│   │   ├── UpdateView.swift      # Single/multi track update UI
│   │   ├── UpdateWorkflowView.swift  # Staged update workflow wrapper
│   │   ├── DryRunSummaryView.swift   # Preview-only results display
│   │   ├── ReportsView.swift     # Change log and analytics charts
│   │   ├── SettingsView.swift    # App preferences
│   │   ├── SubscriptionView.swift # StoreKit paywall UI
│   │   ├── OnboardingView.swift  # First-run script installation
│   │   ├── GenreMappingsEditor.swift  # Custom genre mapping UI
│   │   └── Components/           # Reusable view fragments (app-specific)
│   │       ├── FeatureGatedView.swift  # Paywall wrapper component
│   │       ├── ArtistRow.swift        # Browse list row
│   │       ├── AlbumCard.swift        # Browse album card
│   │       ├── MetricCard.swift       # Dashboard stat card
│   │       ├── GaugeView.swift        # Dashboard gauge
│   │       └── QuickActionButton.swift
│   └── ViewModels/               # @Observable view models (@MainActor)
│       ├── UpdateViewModel.swift # Update workflow state machine
│       ├── WorkflowViewModel.swift  # Batch processing state
│       └── DashboardViewModel.swift # Dashboard metrics
│
├── Packages/
│   ├── Core/                     # Pure domain logic — no external deps
│   │   ├── Package.swift         # swift-tools-version: 6.0, macOS 15
│   │   ├── Sources/Core/
│   │   │   ├── Models/           # Domain types used everywhere
│   │   │   │   ├── Track.swift            # Primary domain model (struct, Sendable, Codable)
│   │   │   │   ├── Protocols.swift        # Service protocol definitions
│   │   │   │   ├── TrackStatus.swift      # TrackKind enum + editability
│   │   │   │   ├── ProgressUpdate.swift   # Async progress streaming model
│   │   │   │   ├── AlbumType.swift        # Album classification (studio/live/compilation)
│   │   │   │   ├── AppFeature.swift       # Feature enum with tier requirements
│   │   │   │   └── Tier.swift             # Subscription tiers (free/weekPass/pro)
│   │   │   ├── Config/
│   │   │   │   └── AppConfiguration.swift # JSON-backed config (Codable)
│   │   │   ├── Genre/
│   │   │   │   └── GenreDeterminator.swift # Dominant genre from earliest album
│   │   │   ├── Year/
│   │   │   │   ├── YearDeterminator.swift  # Year orchestrator (pure logic)
│   │   │   │   ├── YearScorer.swift        # Release candidate scoring
│   │   │   │   ├── YearValidator.swift     # Year range validation
│   │   │   │   ├── YearFallbackStrategy.swift # Fallback rules when API fails
│   │   │   │   └── YearTypes.swift         # ReleaseCandidate, YearDetermination types
│   │   │   ├── Matching/
│   │   │   │   ├── AlbumMatcher.swift      # Fuzzy album name matching
│   │   │   │   └── ArtistMatcher.swift     # Fuzzy artist name matching
│   │   │   ├── Utils/
│   │   │   │   ├── Normalization.swift     # String normalization for matching
│   │   │   │   ├── ScriptDetector.swift    # Non-Latin script detection
│   │   │   │   └── MetadataUtils.swift     # Track metadata helpers
│   │   │   └── Infra/
│   │   │       ├── Logging.swift          # AppLogger factory (os.Logger)
│   │   │       └── SignpostMarkers.swift   # os.signpost performance markers
│   │   └── Tests/CoreTests/      # 27 test files
│   │       ├── Fixtures/          # JSON fixture files for parity tests
│   │       └── [*Tests.swift]     # Unit + parity tests
│   │
│   ├── Services/                 # External world — APIs, Music.app, persistence
│   │   ├── Package.swift         # Deps: Core + GRDB 7.x
│   │   ├── Sources/Services/
│   │   │   ├── Apple/            # Music.app interaction
│   │   │   │   ├── AppleScriptBridge.swift  # actor — NSUserAppleScriptTask execution
│   │   │   │   ├── ScriptInstaller.swift    # Copies .applescript files to user dir
│   │   │   │   └── InputSanitizer.swift     # Script code + data value sanitization
│   │   │   ├── MusicLibraryReader.swift     # actor — MusicKit library reads
│   │   │   ├── API/              # External metadata APIs
│   │   │   │   ├── APIOrchestrator.swift    # actor — parallel multi-source fan-out
│   │   │   │   ├── MusicBrainzClient.swift  # MusicBrainz REST API
│   │   │   │   ├── DiscogsClient.swift      # Discogs REST API
│   │   │   │   ├── AppleMusicSearchClient.swift  # Apple Music catalog search
│   │   │   │   ├── MusicBrainzModels.swift  # Codable response models
│   │   │   │   ├── DiscogsModels.swift      # Codable response models
│   │   │   │   ├── TokenBucketRateLimiter.swift  # actor — token bucket rate limiting
│   │   │   │   ├── RetryUtility.swift       # Exponential backoff retry helper
│   │   │   │   └── KeychainHelper.swift     # Keychain API key storage
│   │   │   ├── Network/
│   │   │   │   └── NetworkReachabilityMonitor.swift  # NWPathMonitor wrapper
│   │   │   ├── Persistence/
│   │   │   │   ├── GRDB/         # API response cache (SQLite)
│   │   │   │   │   ├── GRDBCacheService.swift   # actor — CacheService impl
│   │   │   │   │   ├── GRDBModels.swift          # GRDB table models
│   │   │   │   │   └── GRDBMigrations.swift      # Schema migrations
│   │   │   │   └── SwiftData/    # Track state + change log
│   │   │   │       ├── PersistedTrack.swift      # @Model for track processing state
│   │   │   │       ├── PersistedChangeLogEntry.swift  # @Model for undo log
│   │   │   │       ├── SwiftDataTrackStore.swift     # actor — TrackStateStore impl
│   │   │   │       ├── SwiftDataChangeLogStore.swift  # actor — ChangeLogStore impl
│   │   │   │       └── ModelContainerFactory.swift    # SwiftData stack setup
│   │   │   ├── Subscription/
│   │   │   │   ├── SubscriptionService.swift  # StoreKit 2 subscription management
│   │   │   │   └── FeatureGate.swift          # @MainActor tier-based access control
│   │   │   └── Workflow/         # Orchestration and processing
│   │   │       ├── UpdateCoordinator.swift    # actor — central update orchestrator
│   │   │       ├── BatchProcessor.swift       # actor — batch with pause/resume/cancel
│   │   │       ├── UndoCoordinator.swift      # actor — undo/revert operations
│   │   │       ├── CheckpointManager.swift    # Batch resume checkpointing
│   │   │       ├── LibrarySyncService.swift   # Library sync and delta detection
│   │   │       ├── ChangePreviewPipeline.swift # Struct — filter/group proposed changes
│   │   │       ├── DryRunReport.swift         # Dry-run summary generation
│   │   │       ├── CSVExporter.swift          # CSV export of change log
│   │   │       └── TrackIDMapper.swift        # MusicKit ID ↔ AppleScript ID mapping
│   │   └── Tests/ServicesTests/  # 30 test files
│   │
│   └── SharedUI/                 # Design system and reusable SwiftUI components
│       ├── Package.swift         # Deps: Core only
│       ├── Sources/SharedUI/
│       │   ├── TrackRow.swift         # Track list row component
│       │   ├── TrackDetailView.swift  # Track detail popover/sheet
│       │   ├── ConfidenceBadge.swift  # Percentage confidence indicator
│       │   ├── ProgressRing.swift     # Circular progress indicator
│       │   ├── TierBadge.swift        # Pro/Week Pass tier label
│       │   ├── PaywallOverlay.swift   # Feature locked overlay
│       │   ├── EmptyStateView.swift   # Empty list placeholder
│       │   ├── Theme/
│       │   │   ├── DesignTokens.swift  # Spacing, Radius, AppFont enums
│       │   │   └── AyuColors.swift     # Ayu color palette
│       │   ├── Reports/
│       │   │   └── ReportsChangeLog.swift  # Change history list
│       │   └── Charts/
│       │       └── ReportsCharts.swift    # Swift Charts usage for analytics
│       └── Tests/SharedUITests/
│
├── Tests/                        # App-level tests (separate from package tests)
│   ├── GenreUpdaterTests/        # App-level unit tests
│   ├── IntegrationTests/         # Require live Music.app (local only)
│   │   ├── AppleScriptIntegrationTests.swift
│   │   └── MusicLibraryIntegrationTests.swift
│   └── UITests/                  # XCUITest critical flows
│       ├── NavigationTests.swift
│       ├── OnboardingFlowTests.swift
│       └── UpdateFlowTests.swift
│
├── Resources/
│   ├── Scripts/                  # AppleScript source files (5 files)
│   │   ├── fetch_tracks.applescript
│   │   ├── fetch_tracks_by_ids.applescript
│   │   ├── fetch_track_ids.applescript
│   │   ├── batch_update_tracks.applescript
│   │   └── update_property.applescript
│   └── GenreUpdater.storekit     # StoreKit configuration for testing
│
├── docs/
│   ├── plans/                    # PRD.md, TDD.md (source of truth hierarchy)
│   ├── tasks/                    # Phase task files (phase-*.md with checkboxes)
│   ├── appstore/                 # App Store metadata
│   └── lessons/                  # Lessons learned notes
│
├── scripts/
│   └── validate-entitlements.sh  # CI entitlements whitelist check
│
├── .claude/
│   ├── agents/                   # Custom agents (swift-expert, swiftui-expert, scrum-master)
│   └── hooks/                    # Pre-commit and quality gate hooks
│
├── .github/workflows/            # CI pipeline
├── .planning/codebase/           # GSD mapping documents (this directory)
├── GenreUpdater.xcodeproj/       # Xcode project (generated by XcodeGen)
├── project.yml                   # XcodeGen spec
├── GenreUpdater.entitlements     # Sandbox + scripting-targets + network
├── Justfile                      # Task runner (just build/test/lint/ci)
├── .swiftlint.yml                # SwiftLint rules
└── .swiftformat                  # SwiftFormat rules
```

## Directory Purposes

**`App/`:**
- Purpose: SwiftUI app target — entry point, views, view models, composition root
- Contains: `@main` struct, `AppDependencies` DI container, all screens, `@Observable` view models
- Key files: `App/GenreUpdaterApp.swift`, `App/AppDependencies.swift`, `App/Views/MainView.swift`

**`Packages/Core/Sources/Core/`:**
- Purpose: Zero-dependency business logic and domain types
- Contains: All types safe to use without any framework import beyond Foundation
- Key files: `Models/Track.swift`, `Models/Protocols.swift`, `Genre/GenreDeterminator.swift`, `Year/YearDeterminator.swift`

**`Packages/Services/Sources/Services/`:**
- Purpose: All I/O and external service integrations
- Contains: Actors for Music.app, APIs, persistence; workflow orchestrators
- Key files: `Apple/AppleScriptBridge.swift`, `MusicLibraryReader.swift`, `API/APIOrchestrator.swift`, `Workflow/UpdateCoordinator.swift`

**`Packages/SharedUI/Sources/SharedUI/`:**
- Purpose: Design system — components and tokens used by both App and potentially other targets
- Contains: Reusable views that depend only on `Core.Track` (no Services types)
- Key files: `Theme/DesignTokens.swift`, `Theme/AyuColors.swift`, `TrackRow.swift`

**`Resources/Scripts/`:**
- Purpose: AppleScript source files bundled with the app
- Generated: No (hand-authored)
- Committed: Yes — `ScriptInstaller` copies these to `~/Library/Application Scripts/<bundle-id>/`

## Key File Locations

**Entry Points:**
- `App/GenreUpdaterApp.swift`: `@main` struct, `ContentView` router, menu commands
- `App/AppDependencies.swift`: Service wiring and initialization order

**Domain Model:**
- `Packages/Core/Sources/Core/Models/Track.swift`: `Track` struct + `ChangeLogEntry`
- `Packages/Core/Sources/Core/Models/Protocols.swift`: All service protocol definitions

**Core Algorithms:**
- `Packages/Core/Sources/Core/Genre/GenreDeterminator.swift`: Genre from earliest album
- `Packages/Core/Sources/Core/Year/YearDeterminator.swift`: Year orchestration (pure)
- `Packages/Core/Sources/Core/Year/YearScorer.swift`: Release candidate scoring
- `Packages/Core/Sources/Core/Matching/AlbumMatcher.swift`: Fuzzy album matching
- `Packages/Core/Sources/Core/Utils/Normalization.swift`: String normalization

**Update Workflow:**
- `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift`: Central orchestrator
- `Packages/Services/Sources/Services/Workflow/BatchProcessor.swift`: Batch with progress streaming
- `Packages/Services/Sources/Services/Workflow/ChangePreviewPipeline.swift`: Preview/filter

**Persistence:**
- `Packages/Services/Sources/Services/Persistence/SwiftData/PersistedTrack.swift`: Track `@Model`
- `Packages/Services/Sources/Services/Persistence/GRDB/GRDBCacheService.swift`: API cache actor

**Music.app Integration:**
- `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift`: Write via NSUserAppleScriptTask
- `Packages/Services/Sources/Services/MusicLibraryReader.swift`: Read via MusicKit

**Configuration:**
- `Packages/Core/Sources/Core/Config/AppConfiguration.swift`: JSON-backed config struct
- `App/GenreUpdater.entitlements`: Sandbox entitlements

**Design Tokens:**
- `Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift`: `Spacing`, `Radius`, `AppFont`
- `Packages/SharedUI/Sources/SharedUI/Theme/AyuColors.swift`: `Ayu` color palette

**CI/Build:**
- `Justfile`: Task runner commands (`just ci`, `just build`, `just test`, etc.)
- `project.yml`: XcodeGen spec — regenerate with `xcodegen generate`
- `.github/workflows/`: CI pipeline definitions

## Module Boundaries and Public API Surface

**Core public API surface** (all types in `Packages/Core/Sources/Core/` must be `public` to cross the package boundary):
- All model types: `Track`, `ChangeLogEntry`, `ChangeType`, `TrackKind`, `YearResult`, `GenreResult`, `ProgressUpdate`, `AlbumType`, `Tier`, `AppFeature`
- All protocol definitions: `CacheService`, `TrackStateStore`, `ExternalAPIService`, `AppleScriptClient`, `ChangeLogStore`, `RateLimiter`, etc.
- Algorithm types: `GenreDeterminator`, `YearDeterminator`, `YearScorer`, `YearValidator`, `YearFallbackStrategy`, `AlbumMatcher`, `ArtistMatcher`
- `AppConfiguration` and sub-config structs
- `AppLogger` factory

**Services public API surface** (used by App target):
- Actor types: `AppleScriptBridge`, `MusicLibraryReader`, `APIOrchestrator`, `GRDBCacheService`, `SwiftDataTrackStore`, `SwiftDataChangeLogStore`, `UpdateCoordinator`, `BatchProcessor`, `UndoCoordinator`, `LibrarySyncService`
- Class types: `SubscriptionService`, `FeatureGate`, `ScriptInstaller`
- Struct types: `ChangePreviewPipeline`, `ProposedChange`, `BatchUpdateResult`, `UpdateOptions`, `DryRunReport`
- Error enums: `AppleScriptBridgeError`, `MusicLibraryError`, `UpdateCoordinatorError`, `BatchProcessorError`, `FeatureGateError`

**SharedUI public API surface:**
- Component views: `TrackRow`, `TrackDetailView`, `ConfidenceBadge`, `ProgressRing`, `TierBadge`, `PaywallOverlay`, `EmptyStateView`, `ReportsChangeLog`, `ReportsCharts`
- Design tokens: `Spacing`, `Radius`, `AppFont`, `Ayu`

## Naming Conventions

**Files:**
- PascalCase matching the primary type: `UpdateCoordinator.swift`, `PersistedTrack.swift`
- Model files for groups: `MusicBrainzModels.swift`, `DiscogsModels.swift`, `GRDBModels.swift`
- Test files: `{Type}Tests.swift`; parity tests: `{Area}ParityTests.swift`

**Directories:**
- PascalCase for domain groupings: `Workflow/`, `Persistence/`, `Matching/`, `Apple/`
- Lowercase for infra/meta: `Models/`, `Utils/`, `Infra/`, `Config/`, `Theme/`

**Types:**
- Actors: `AppleScriptBridge`, `APIOrchestrator` (same PascalCase as classes — context distinguishes)
- Error enums: `{Module}Error` suffix — `AppleScriptBridgeError`, `MusicLibraryError`
- Protocol suffix: none (plain noun protocols like `CacheService`, `TrackStateStore`)
- ViewModels: `{Feature}ViewModel` — `UpdateViewModel`, `WorkflowViewModel`

## Where to Add New Code

**New domain model or protocol:**
- Implementation: `Packages/Core/Sources/Core/Models/`
- Must be `public`
- Add tests in `Packages/Core/Tests/CoreTests/`

**New pure algorithm (no I/O):**
- Implementation: New file in relevant `Packages/Core/Sources/Core/{Domain}/` subfolder
- Must be a `struct` (or `enum`) conforming to `Sendable`
- Add tests in `Packages/Core/Tests/CoreTests/`

**New external API client:**
- Implementation: `Packages/Services/Sources/Services/API/`
- Pattern: `public actor` conforming to `ExternalAPIService` protocol from Core
- Add tests in `Packages/Services/Tests/ServicesTests/`

**New workflow service:**
- Implementation: `Packages/Services/Sources/Services/Workflow/`
- Pattern: `public actor` for stateful services; `public struct` for pure pipeline stages
- Wire in `App/AppDependencies.swift` `initializeWorkflowServices()`

**New SwiftUI screen:**
- Screen: `App/Views/{Feature}View.swift`
- View model (if needed): `App/ViewModels/{Feature}ViewModel.swift` — `@Observable @MainActor final class`
- Register in `App/Views/MainView.swift` navigation

**New reusable SwiftUI component:**
- If it depends only on `Core` types: `Packages/SharedUI/Sources/SharedUI/`
- If it needs `Services` types: `App/Views/Components/`

**New persistence model:**
- SwiftData `@Model`: `Packages/Services/Sources/Services/Persistence/SwiftData/`
- Add migration in `Packages/Services/Sources/Services/Persistence/GRDB/GRDBMigrations.swift` (for GRDB)
- Register `@Model` in `ModelContainerFactory.swift`

**New AppleScript:**
- Source: `Resources/Scripts/{script_name}.applescript`
- Install path handled by `ScriptInstaller` — update its file list

## Test Organization

**Package tests (automated in CI):**
- Core: `Packages/Core/Tests/CoreTests/` — 27 test files; run with `swift test --package-path Packages/Core`
- Services: `Packages/Services/Tests/ServicesTests/` — 30 test files; run with `swift test --package-path Packages/Services`
- Fixtures: `Packages/Core/Tests/CoreTests/Fixtures/` — JSON files for Python parity tests

**App-level tests (Xcode target):**
- Unit: `Tests/GenreUpdaterTests/`
- Integration (require Music.app, local only): `Tests/IntegrationTests/`
- UI (XCUITest): `Tests/UITests/` — `NavigationTests`, `OnboardingFlowTests`, `UpdateFlowTests`

**Parity tests** (suffix `ParityTests.swift`) validate Swift algorithms produce identical results to the ported Python implementation using fixture JSON files.

## Special Directories

**`.build` / `.build.nosync`:**
- Purpose: SPM build output (per-package)
- Generated: Yes
- Committed: No (`.build.nosync` keeps iCloud from syncing build artifacts)

**`.planning/codebase/`:**
- Purpose: GSD mapping documents (this file)
- Generated: Yes (by `/gsd:map-codebase` agent)
- Committed: No (ephemeral planning artifacts)

**`.claude/hooks/`:**
- Purpose: Claude Code quality gate hooks (SwiftLint, docs sync, push tests)
- Generated: No (hand-authored)
- Committed: Yes

**`.claude/agents/`:**
- Purpose: Custom agent definitions (`swift-expert`, `swiftui-expert`, `scrum-master`)
- Generated: No
- Committed: No (gitignored — set up per machine)

---

*Structure analysis: 2026-02-22*
