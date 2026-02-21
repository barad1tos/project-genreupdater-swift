---
phase: 5
title: "Application Workflows"
status: done
priority: high
depends_on:
  - "Phase 3 (algorithms)"
  - "Phase 4 (API + cache)"
---
> Parent: [[PRD]]

**Related:** [[phase-3-core-algorithms|Phase 3: Core Algorithms]] | [[phase-4-api-cache|Phase 4: API + Cache]] | [[phase-6-views-polish|Phase 6: Views]]
**Technical ref:** [[TDD#src/app/ → Sources/App/]] | [[TDD#Decision 5 DI Container → Constructor Injection + @Environment]]

# Phase 5: Application Workflows

## Context

Інтеграція всіх компонентів з Phase 2-4 у повноцінні робочі процеси. Від "натисни кнопку Update" до "зміни записані в Music.app з можливістю undo". Checkpoint/resume для довгих batch-операцій.

## Deliverables

### UpdateCoordinator
> **TDD ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] (`update_executor.py` + `track_updater.py` merge → `UpdateExecutor.swift` 🔴) | [[TDD#src/app/ → Sources/App/]] (orchestration layer)

- [x]Створити `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift`
- [x]Full update pipeline orchestration: read → process → preview → write → log
- [x]Single track update flow
- [x]Multi-track update flow
- [x]Progress reporting через ProgressUpdate stream
- [x]Error aggregation (partial failures allowed)
- [x]Dry-run mode для preview без запису
- [x]Unit tests: full pipeline, partial failures, dry-run
- [x]Integration test: end-to-end з real Music.app

### CheckpointManager
> **TDD ref:** [[TDD#src/app/features/ → Sources/App/Workflows/]] (batch workflow infrastructure) | [[TDD#Risks & Mitigation]] (SwiftData performance 30K+ tracks — checkpoint prevents data loss on crash)

- [x]Створити `Packages/Services/Sources/Services/Workflow/CheckpointManager.swift`
- [x]Save progress of long-running batch operations
- [x]Resume from last checkpoint після app restart
- [x]Checkpoint storage: JSON file in app support directory
- [x]Auto-checkpoint кожні N треків (configurable)
- [x]Cleanup old checkpoints
- [x]Unit tests: save, resume, cleanup, corruption handling

### UndoCoordinator
> **TDD ref:** Немає прямого Python-аналогу — новий Swift requirement. Бізнес-обґрунтування: [[PRD#Undo/Redo]]. Персистенція через SwiftData ([[TDD#Decision 8 3-Tier Cache → SwiftData + GRDB + NSCache]])

- [x]Створити `Packages/Services/Sources/Services/Workflow/UndoCoordinator.swift`
- [x]Central coordinator для reverting changes
- [x]Individual change revert (single ChangeLogEntry)
- [x]Batch revert (all changes in a session)
- [x]Selective revert (user picks which changes to undo)
- [x]Revert history persists across app launches (JSON file in Application Support)
- [x]Confirmation dialog before destructive undo
- [x]Unit tests: individual, batch, selective, persistence

### BatchProcessor
> **TDD ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] (`year_batch.py` 528 + `batch_fetcher.py` 390 → `BatchFlow.swift` merge) | [[TDD#Decision 3 asyncio.gather → async let / TaskGroup]] (`TaskGroup` для dynamic batch concurrency)

- [x]Створити `Packages/Services/Sources/Services/Workflow/BatchProcessor.swift`
- [x]Batch operations з progress streaming
- [x]Configurable concurrency (max parallel operations)
- [x]Pause/resume/cancel controls
- [x]Integration з CheckpointManager
- [x]ETA calculation based on processing speed
- [x]Feature gating через FeatureGate: доступно для Week Pass (.weekPass) та Pro (.pro)
- [x]Unit tests: progress, pause/resume, cancel, checkpointing

### LibrarySyncService
> **TDD ref:** Немає прямого Python-аналогу — новий Swift requirement для incremental sync. Пов'язано з [[TDD#Music.app Integration]] (MusicKit `MusicLibraryRequest` для detect changes)

- [x]Створити `Packages/Services/Sources/Services/Workflow/LibrarySyncService.swift`
- [x]Detect library changes (new tracks, modified tracks)
- [x]Suggest updates для нових треків
- [x]Background sync (Pro-exclusive feature, Auto-sync — not available in Week Pass)
- [x]Diff: current library vs last known state
- [x]Unit tests: change detection, diff calculation

### Change Preview Pipeline
> **TDD ref:** [[TDD#src/app/ → Sources/App/]] (result presentation before write — Python CLI output → SwiftUI preview table)

- [x]Preview aggregation: collect all proposed changes
- [x]Confidence threshold filtering (configurable)
- [x]Group by artist/album для зручного перегляду
- [x]Accept all / reject all / toggle individual
- [x]Export preview to CSV (Pro)

## Files (~6)

| File | Description |
|------|-------------|
| `Services/Workflow/UpdateCoordinator.swift` | Full pipeline orchestration |
| `Services/Workflow/CheckpointManager.swift` | Save/restore progress |
| `Services/Workflow/UndoCoordinator.swift` | Revert changes |
| `Services/Workflow/BatchProcessor.swift` | Batch operations |
| `Services/Workflow/LibrarySyncService.swift` | Library change detection |
| `Services/Workflow/ChangePreviewPipeline.swift` | Preview aggregation |
| `Services/Workflow/TrackIDMapper.swift` | MusicKit ↔ AppleScript ID mapping (Phase 5.5) |
| `Services/Network/NetworkReachabilityMonitor.swift` | NWPathMonitor wrapper (Phase 5.5) |

## Acceptance Criteria

- [x]Full pipeline: read → process → preview → write → verify працює end-to-end
- [x]Checkpoint/resume працює після app restart
- [x]Undo reverts individual та batch changes
- [x]Progress updates стрімяться до UI в real-time
- [x]Batch processing працює з pause/resume/cancel
- [x]Pro features gated correctly
- [x]`swift build` + `swift test` проходять

## Dependencies

- Phase 3 (GenreManager, YearManager, ScoringEngine)
- Phase 4 (API clients, cache, rate limiters)
- Phase 2 (SubscriptionService, FeatureGate, persistence)

## Notes

- UpdateCoordinator — центральна точка інтеграції, найскладніший компонент фази
- CheckpointManager критичний для UX: користувач не має втрачати прогрес
- Undo має бути надійним — це довіра користувача до додатку

## Post-Phase Audit Fixes (Phase 5.5)

Closes H1/H3 from Phase 1–5 audit:

- **H1**: `PersistedChangeLogEntry` SwiftData model + `SwiftDataChangeLogStore` + `ModelContainerFactory` — enables SwiftData-backed change log persistence alongside existing JSON persistence; `UndoCoordinator` optionally writes to both
- **H3**: `PersistedTrack.changeLog` `@Relationship` to `PersistedChangeLogEntry` with cascade delete
- **Pre-existing fixes**: Updated `UpdateCoordinatorTests` to use temp directory (fixed flaky assertion), fixed `empty_count` lint violation in `FeatureGateTests`
