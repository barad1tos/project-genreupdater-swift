---
phase: 05-dashboard-redesign
plan: 01
subsystem: ui
tags: [swiftui, swiftdata, dashboard, gauge, metrics, caching, trends]

requires:
  - phase: 03-sharedui-component-library
    provides: HeroGauge component, AyuColors, DesignTokens (Spacing, AppFont, Motion)
  - phase: 04-navigation-shell
    provides: NavigationCategory enum for navigation callbacks
provides:
  - PersistedMetricsSnapshot SwiftData model for cached-first dashboard loading
  - DashboardViewModel with loading state machine, trends, and consistency metric
  - HeroGauge with redesigned colors (purple/info/accent), stacked layout, click callback
affects: [05-02-dashboard-view-rewrite, 08-animations-polish]

tech-stack:
  added: []
  patterns: [Two-phase cached-first loading (snapshot then live), Single-row SwiftData model with inline previous values for trends]

key-files:
  created:
    - Packages/Services/Sources/Services/Persistence/SwiftData/PersistedMetricsSnapshot.swift
  modified:
    - Packages/Services/Sources/Services/Persistence/SwiftData/ModelContainerFactory.swift
    - App/ViewModels/DashboardViewModel.swift
    - App/Views/Components/MetricCard.swift
    - Packages/SharedUI/Sources/SharedUI/Components/HeroGauge.swift

key-decisions:
  - "Single-row PersistedMetricsSnapshot with inline previous values instead of history table for trend calculation"
  - "TrendDirection moved from MetricCard.swift to DashboardViewModel.swift as ViewModel concern"
  - "GaugeLayer made public for onArcTapped callback to work across App/SharedUI boundary"
  - "Shared detectLayer method for both hover and tap avoids code duplication"
  - "Static fill on appear (no animation) per CONTEXT.md -- Phase 8 will add draw-in animation"

patterns-established:
  - "Two-phase cached-first loading: loadCachedMetrics(snapshot) then refreshFromLive(tracks)"
  - "DashboardLoadingState enum: explicit state machine prevents invalid UI configurations"
  - "Inline previous values in SwiftData model: avoids history table for simple trend delta"

requirements-completed: [DASH-01, DASH-02, DASH-03]

duration: 8min
completed: 2026-02-23
---

# Phase 05 Plan 01: Dashboard Data Layer and HeroGauge Redesign Summary

**PersistedMetricsSnapshot for cached-first loading, DashboardViewModel with 7-state machine and trend deltas, HeroGauge with Ayu purple/info/accent stacked arcs and click navigation**

## Performance

- **Duration:** 8 min
- **Started:** 2026-02-23T08:25:03Z
- **Completed:** 2026-02-23T08:33:47Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments

- PersistedMetricsSnapshot @Model with 12 stored properties (current + previous metrics) and 3 computed coverages for instant-load on launch
- DashboardViewModel rewritten with DashboardLoadingState (shimmer/cached/updating/live/error/permissionDenied/emptyLibrary), DashboardMetrics struct, and trend calculations comparing current to previous scan
- HeroGauge redesigned: Genre=Ayu.purple, Year=Ayu.info, Consistency=Ayu.accent; 2pt stacked arc gap with shadow depth; public GaugeLayer + onArcTapped callback; DetailedCounts for hover drill-down; static fill on appear

## Task Commits

Each task was committed atomically:

1. **Task 1: Create PersistedMetricsSnapshot model and register in ModelContainerFactory** - `663340a` (feat)
2. **Task 2: Extend DashboardViewModel with loading states, cached-first pattern, and trends** - `577c0ad` (feat)
3. **Task 3: Update HeroGauge colors, stacked layout, shadow, and click callback** - `b1ef86f` (feat)

## Files Created/Modified

- `Packages/Services/Sources/Services/Persistence/SwiftData/PersistedMetricsSnapshot.swift` - SwiftData @Model for cached dashboard metrics (12 stored + 3 computed properties)
- `Packages/Services/Sources/Services/Persistence/SwiftData/ModelContainerFactory.swift` - Added PersistedMetricsSnapshot.self to both create() and createInMemory() schemas
- `App/ViewModels/DashboardViewModel.swift` - Rewritten with DashboardLoadingState enum, DashboardMetrics struct, TrendDirection, cached-first loading, trend direction + delta
- `App/Views/Components/MetricCard.swift` - Removed TrendDirection enum (moved to DashboardViewModel)
- `Packages/SharedUI/Sources/SharedUI/Components/HeroGauge.swift` - Redesigned: new colors, 2pt arc gap, shadow on value arcs, public GaugeLayer, onArcTapped callback, DetailedCounts, static fill on appear

## Decisions Made

- Single-row PersistedMetricsSnapshot with inline `previous*` fields instead of a history table -- simpler for single-comparison trend calculation, no migration complexity
- TrendDirection moved from MetricCard.swift to DashboardViewModel.swift -- it's a ViewModel concern (data-driven), not a view concern
- GaugeLayer made public enum at file scope -- required for onArcTapped callback to be usable from App target across package boundary
- Shared `detectLayer(at:in:maxRadius:)` method used by both hover and tap detection -- avoids duplicating ring detection logic
- Static fill on appear (no animation) per CONTEXT.md -- Phase 8 will add polished draw-in animation
- Consistency = tracks with BOTH genre AND year filled, using safe `track.genre.map { !$0.isEmpty } ?? false` pattern (no force unwrap)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] TrendDirection duplication between MetricCard and DashboardViewModel**
- **Found during:** Task 2 (DashboardViewModel rewrite)
- **Issue:** Plan said to move TrendDirection from MetricCard to DashboardViewModel, but both files were in the same App target causing duplicate declaration
- **Fix:** Removed TrendDirection from MetricCard.swift, kept it in DashboardViewModel.swift with `tint` property preserved for MetricCard usage
- **Files modified:** App/Views/Components/MetricCard.swift
- **Verification:** Build passes, MetricCard still uses trend.icon and trend.tint
- **Committed in:** 577c0ad (Task 2 commit)

**2. [Rule 1 - Bug] SwiftLint force_unwrapping violation in consistency check**
- **Found during:** Task 2 (DashboardViewModel rewrite)
- **Issue:** `track.genre != nil && !track.genre!.isEmpty` triggers SwiftLint force_unwrapping rule
- **Fix:** Changed to `track.genre.map { !$0.isEmpty } ?? false` using safe Optional.map pattern
- **Files modified:** App/ViewModels/DashboardViewModel.swift
- **Verification:** SwiftLint passes with 0 violations
- **Committed in:** 577c0ad (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both fixes necessary for correctness and lint compliance. No scope creep.

## Issues Encountered

- DashboardView.swift has temporary build errors referencing removed ViewModel API (totalTracks, genreFillPercent, uniqueGenres, topGenres, isLoading) -- expected per plan, will be resolved by Plan 02 DashboardView rewrite
- SwiftFormat numberFormatting rule auto-fixed preview number literals (removed underscore separators for consistency)

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 02 (DashboardView rewrite) can now proceed with all dependencies in place:
  - DashboardViewModel provides loadCachedMetrics/refreshFromLive + DashboardLoadingState for view switching
  - HeroGauge accepts new colors, onArcTapped callback, and DetailedCounts
  - PersistedMetricsSnapshot ready for ModelContext queries
- DashboardView.swift currently has build errors from removed API -- Plan 02 will rewrite it entirely

## Self-Check: PASSED

- FOUND: Packages/Services/Sources/Services/Persistence/SwiftData/PersistedMetricsSnapshot.swift
- FOUND: App/ViewModels/DashboardViewModel.swift
- FOUND: Packages/SharedUI/Sources/SharedUI/Components/HeroGauge.swift
- FOUND: .planning/phases/05-dashboard-redesign/05-01-SUMMARY.md
- FOUND: commit 663340a
- FOUND: commit 577c0ad
- FOUND: commit b1ef86f

---
*Phase: 05-dashboard-redesign*
*Completed: 2026-02-23*
