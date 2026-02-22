# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** The app must feel fast, intuitive, and satisfying to use on a 38K+ track library — users should never feel lost, never see empty states, and always understand what the app can do for their music collection.
**Current focus:** Phase 1 — Design System Foundation

## Current Position

Phase: 1 of 8 (Design System Foundation)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-02-22 — Roadmap created; 25 requirements mapped across 8 phases

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: —
- Total execution time: —

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: —
- Trend: —

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Use SwiftUI List (not LazyVStack) for Browse — cell recycling required at 2,271 artists / 38K tracks
- [Roadmap]: SwiftUI-Shimmer is the only new dependency (SharedUI Package.swift); all other tech is existing stack
- [Roadmap]: @Observable ViewModels must be @State private var — without @State SwiftUI recreates on every parent re-render
- [Roadmap]: macOS 15 scroll regression — apply .contentShape(.rect) on all scrollable rows proactively
- [Roadmap]: Theme switching requires both preferredColorScheme on WindowGroup AND NSApp.appearance for AppKit surfaces

### Pending Todos

None yet.

### Blockers/Concerns

- Ayu light-mode fgPrimary (0x5C6166) on white is ~4.2:1, just below WCAG AA — exact fix needed in Phase 1
- SwiftUI-Shimmer version number needs verification at https://github.com/markiv/SwiftUI-Shimmer/releases before Phase 3
- Table vs List for track-level Browse rows warrants a prototype spike before committing in Phase 6

## Session Continuity

Last session: 2026-02-22
Stopped at: Roadmap created and files written; ready to plan Phase 1
Resume file: None
