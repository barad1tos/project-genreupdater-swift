# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** The app must feel fast, intuitive, and satisfying to use on a 38K+ track library — users should never feel lost, never see empty states, and always understand what the app can do for their music collection.
**Current focus:** Phase 5 — Dashboard Redesign

## Current Position

Phase: 5 of 8 (Dashboard Redesign)
Plan: 1 of 2 in current phase
Status: In Progress
Last activity: 2026-02-23 — Phase 5 Plan 1 complete

Progress: [██████░░░░] 56%

## Performance Metrics

**Velocity:**
- Total plans completed: 9
- Average duration: 7min
- Total execution time: 61min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-design-system-foundation | 2 | 14min | 7min |
| 02-theme-switching | 1 | 15min | 15min |
| 03-sharedui-component-library | 3 | 10min | 3min |
| 04-navigation-shell | 2 | 14min | 7min |
| 05-dashboard-redesign | 1 | 8min | 8min |

**Recent Trend:**
- Last 5 plans: 3min, 4min, 6min, 8min, 8min
- Trend: stable

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
- [Phase 04]: SidebarView.Item struct for data-driven sidebar instead of generic/protocol approach
- [Phase 04]: NSImage copy + isTemplate = true for Lucide icon foregroundStyle tinting
- [Phase 04]: LucideIcons 0.575.0 added to SharedUI (second external dependency after SwiftUI-Shimmer)
- [Phase 04]: LucideIcons added as direct App target dependency for NavigationCategory icon mapping
- [Phase 04]: centeredContent uses frame-based approach (no extra ScrollView) since views already scroll
- [Phase 04]: Opaque generic parameter (some View) for centeredContent per SwiftFormat rule
- [Phase 05]: Single-row PersistedMetricsSnapshot with inline previous values for trend calculation (no history table)
- [Phase 05]: TrendDirection moved from MetricCard to DashboardViewModel as ViewModel concern
- [Phase 05]: GaugeLayer made public for onArcTapped callback across App/SharedUI boundary
- [Phase 05]: Shared detectLayer method for hover and tap avoids ring-detection code duplication
- [Phase 05]: Static fill on appear per CONTEXT.md -- Phase 8 will add draw-in animation

### Pending Todos

None yet.

### Blockers/Concerns

- ~~Ayu light-mode fgPrimary (0x5C6166) on white is ~4.2:1~~ RESOLVED: Research confirmed 6.10:1 on bgPrimary (0xFCFCFC), passes WCAG AA
- ~~SwiftUI-Shimmer version number needs verification~~ RESOLVED: 1.5.1 confirmed, dependency resolves and builds cleanly
- Table vs List for track-level Browse rows warrants a prototype spike before committing in Phase 6
- DashboardView.swift has temporary build errors from removed ViewModel API -- Plan 05-02 will rewrite entirely

## Session Continuity

Last session: 2026-02-23
Stopped at: Completed 05-01-PLAN.md
Resume file: .planning/ROADMAP.md
