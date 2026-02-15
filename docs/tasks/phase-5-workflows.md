---
phase: 5
title: "Application Workflows"
status: planned
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

- [ ] Створити `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift`
- [ ] Full update pipeline orchestration: read → process → preview → write → log
- [ ] Single track update flow
- [ ] Multi-track update flow
- [ ] Progress reporting через ProgressUpdate stream
- [ ] Error aggregation (partial failures allowed)
- [ ] Dry-run mode для preview без запису
- [ ] Unit tests: full pipeline, partial failures, dry-run
- [ ] Integration test: end-to-end з real Music.app

### CheckpointManager
> **TDD ref:** [[TDD#src/app/features/ → Sources/App/Workflows/]] (batch workflow infrastructure) | [[TDD#Risks & Mitigation]] (SwiftData performance 30K+ tracks — checkpoint prevents data loss on crash)

- [ ] Створити `Packages/Services/Sources/Services/Workflow/CheckpointManager.swift`
- [ ] Save progress of long-running batch operations
- [ ] Resume from last checkpoint після app restart
- [ ] Checkpoint storage: JSON file in app support directory
- [ ] Auto-checkpoint кожні N треків (configurable)
- [ ] Cleanup old checkpoints
- [ ] Unit tests: save, resume, cleanup, corruption handling

### UndoCoordinator
> **TDD ref:** Немає прямого Python-аналогу — новий Swift requirement. Бізнес-обґрунтування: [[PRD#Undo/Redo]]. Персистенція через SwiftData ([[TDD#Decision 8 3-Tier Cache → SwiftData + GRDB + NSCache]])

- [ ] Створити `Packages/Services/Sources/Services/Workflow/UndoCoordinator.swift`
- [ ] Central coordinator для reverting changes
- [ ] Individual change revert (single ChangeLogEntry)
- [ ] Batch revert (all changes in a session)
- [ ] Selective revert (user picks which changes to undo)
- [ ] Revert history persists across app launches (SwiftData)
- [ ] Confirmation dialog before destructive undo
- [ ] Unit tests: individual, batch, selective, persistence

### BatchProcessor
> **TDD ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] (`year_batch.py` 528 + `batch_fetcher.py` 390 → `BatchFlow.swift` merge) | [[TDD#Decision 3 asyncio.gather → async let / TaskGroup]] (`TaskGroup` для dynamic batch concurrency)

- [ ] Створити `Packages/Services/Sources/Services/Workflow/BatchProcessor.swift`
- [ ] Batch operations з progress streaming
- [ ] Configurable concurrency (max parallel operations)
- [ ] Pause/resume/cancel controls
- [ ] Integration з CheckpointManager
- [ ] ETA calculation based on processing speed
- [ ] Feature gating через FeatureGate: доступно для Week Pass (.weekPass) та Pro (.pro)
- [ ] Unit tests: progress, pause/resume, cancel, checkpointing

### LibrarySyncService
> **TDD ref:** Немає прямого Python-аналогу — новий Swift requirement для incremental sync. Пов'язано з [[TDD#Music.app Integration]] (MusicKit `MusicLibraryRequest` для detect changes)

- [ ] Створити `Packages/Services/Sources/Services/Workflow/LibrarySyncService.swift`
- [ ] Detect library changes (new tracks, modified tracks)
- [ ] Suggest updates для нових треків
- [ ] Background sync (Pro-exclusive feature, Auto-sync — not available in Week Pass)
- [ ] Diff: current library vs last known state
- [ ] Unit tests: change detection, diff calculation

### Change Preview Pipeline
> **TDD ref:** [[TDD#src/app/ → Sources/App/]] (result presentation before write — Python CLI output → SwiftUI preview table)

- [ ] Preview aggregation: collect all proposed changes
- [ ] Confidence threshold filtering (configurable)
- [ ] Group by artist/album для зручного перегляду
- [ ] Accept all / reject all / toggle individual
- [ ] Export preview to CSV (Pro)

## Files (~6)

| File | Description |
|------|-------------|
| `Services/Workflow/UpdateCoordinator.swift` | Full pipeline orchestration |
| `Services/Workflow/CheckpointManager.swift` | Save/restore progress |
| `Services/Workflow/UndoCoordinator.swift` | Revert changes |
| `Services/Workflow/BatchProcessor.swift` | Batch operations |
| `Services/Workflow/LibrarySyncService.swift` | Library change detection |
| `Services/Workflow/ChangePreviewPipeline.swift` | Preview aggregation |

## Acceptance Criteria

- [ ] Full pipeline: read → process → preview → write → verify працює end-to-end
- [ ] Checkpoint/resume працює після app restart
- [ ] Undo reverts individual та batch changes
- [ ] Progress updates стрімяться до UI в real-time
- [ ] Batch processing працює з pause/resume/cancel
- [ ] Pro features gated correctly
- [ ] `swift build` + `swift test` проходять

## Dependencies

- Phase 3 (GenreManager, YearManager, ScoringEngine)
- Phase 4 (API clients, cache, rate limiters)
- Phase 2 (SubscriptionService, FeatureGate, persistence)

## Notes

- UpdateCoordinator — центральна точка інтеграції, найскладніший компонент фази
- CheckpointManager критичний для UX: користувач не має втрачати прогрес
- Undo має бути надійним — це довіра користувача до додатку
