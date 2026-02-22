# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** The app must feel fast, intuitive, and satisfying to use on a 38K+ track library — users should never feel lost, never see empty states, and always understand what the app can do for their music collection.
**Current focus:** Phase 3 — SharedUI Component Library

## Current Position

Phase: 3 of 8 (SharedUI Component Library) -- COMPLETE
Plan: 3 of 3 in current phase
Status: Phase 03 complete, all 3 plans delivered
Last activity: 2026-02-22 — Completed 03-03 (HeroGauge)

Progress: [████░░░░░░] 38%

## Performance Metrics

**Velocity:**
- Total plans completed: 6
- Average duration: 7min
- Total execution time: 39min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-design-system-foundation | 2 | 14min | 7min |
| 02-theme-switching | 1 | 15min | 15min |
| 03-sharedui-component-library | 3 | 10min | 3min |

**Recent Trend:**
- Last 5 plans: 15min, 3min, 3min, 4min
- Trend: stable-fast

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
- [Phase 01]: Used opaque generics (some Equatable) instead of <V: Equatable> per SwiftFormat opaqueGenericParameters rule
- [Phase 01]: fgSecondary light changed to 0x697078 (4.89:1) for WCAG AA; fgPrimary confirmed passing at 6.10:1 (no change needed)
- [Phase 02]: SF Symbol-only segmented picker (no text labels) for cleaner appearance settings
- [Phase 02]: NSApp.appearance = nil for .system mode — tracks OS changes in real time without restart
- [Phase 02]: Both WindowGroup and Settings scenes need independent preferredColorScheme wiring
- [Phase 03]: @preconcurrency import Shimmer for Swift 6 strict concurrency with SwiftUI-Shimmer (swift-tools-version 5.3)
- [Phase 03]: simultaneousGesture DragGesture pattern for press detection — simpler than custom ButtonStyle
- [Phase 03]: GeometryReader for StatCard progress bar — percentage-based width with smooth animation
- [Phase 03]: SF Mono for count badges, AppFont.caption for genre badges — numeric alignment vs semantic styling
- [Phase 03]: SectionIndexBar placed outside List in HStack — avoids coordinate space issues with scroll views
- [Phase 03]: ArcShape conforms to Animatable via animatableData for smooth SwiftUI arc interpolation
- [Phase 03]: Distance-based ring detection using ClosedRange.contains for clean hover logic

### Pending Todos

None yet.

### Blockers/Concerns

- ~~Ayu light-mode fgPrimary (0x5C6166) on white is ~4.2:1~~ RESOLVED: Research confirmed 6.10:1 on bgPrimary (0xFCFCFC), passes WCAG AA
- ~~SwiftUI-Shimmer version number needs verification~~ RESOLVED: 1.5.1 confirmed, dependency resolves and builds cleanly
- Table vs List for track-level Browse rows warrants a prototype spike before committing in Phase 6

## Session Continuity

Last session: 2026-02-22
Stopped at: Completed 03-03-PLAN.md (Phase 03 complete)
Resume file: .planning/phases/03-sharedui-component-library/03-03-SUMMARY.md
