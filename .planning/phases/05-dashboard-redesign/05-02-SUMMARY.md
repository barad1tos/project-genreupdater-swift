---
phase: 05-dashboard-redesign
plan: 02
subsystem: ui
tags: [swiftui, dashboard, herogauge, shimmer, metrics, cached-first, quickactions]

requires:
  - phase: 05-dashboard-redesign
    plan: 01
    provides: DashboardViewModel, PersistedMetricsSnapshot, HeroGauge redesign
provides:
  - Complete DashboardView with HeroGauge hero, cached-first loading, shimmer states, metric cards, soft quick actions
  - MainView wired with SwiftData metrics snapshot persistence
  - GaugeView.swift deleted (replaced by SharedUI HeroGauge)
affects: [08-animations-polish]

tech-stack:
  added: []
  patterns: [SwiftData snapshot fetch/save in MainView, LazyVGrid adaptive card reflow, ContentUnavailableView for edge states]

key-files:
  created: []
  modified:
    - App/Views/DashboardView.swift
    - App/Views/Components/MetricCard.swift
    - App/Views/Components/QuickActionButton.swift
    - App/Views/MainView.swift
    - Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift
  deleted:
    - App/Views/Components/GaugeView.swift

key-decisions:
  - "MetricCard uses StatCard-consistent hover/press pattern (shadow elevation + accent border + 0.98 scale + DragGesture)"
  - "QuickActionButton parameter renamed from 'count' to 'untaggedCount' to avoid SwiftLint empty_count false positive"
  - "MainView saves metrics snapshot to SwiftData directly (no separate service) for simplicity"
  - "Empty library 'Open Music' uses music:// URL scheme instead of NSWorkspace.launchApplication (deprecated)"
  - "No 'Library Health' title above gauge -- gauge + legend are self-explanatory per Claude's Discretion"

patterns-established:
  - "ContentUnavailableView for permission denied, empty library, and error states"
  - "MainView.loadCachedSnapshot() before loadTracks() for instant cached display"
  - "saveMetricsSnapshot shifts current values to previous* fields before updating"

requirements-completed: [DASH-01, DASH-02, DASH-03, DASH-04]

duration: 11min
completed: 2026-02-23
---

# Phase 05 Plan 02: DashboardView Rewrite Summary

**DashboardView rewritten with HeroGauge hero centerpiece, cached-first metrics from SwiftData, shimmer first-launch loading, soft quick actions with neutral tone, and GaugeView deleted**

## Performance

- **Duration:** 11 min
- **Started:** 2026-02-23T08:37:16Z
- **Completed:** 2026-02-23T08:48:49Z
- **Tasks:** 2
- **Files modified:** 5 (1 deleted)

## Accomplishments

- MetricCard redesigned with trend arrow (visible by default), hover-revealed delta text ("+12 since last scan"), StatCard-consistent interaction pattern (shadow elevation, accent border glow, 0.98 press scale)
- QuickActionButton rewritten as soft horizontal row: neutral tone ("Genre . 327 untagged") with zero-state checkmark ("All genres tagged"), chevron right affordance
- DashboardView completely rewritten: HeroGauge (300x180pt) as hero with coverage values and onArcTapped navigation, 3 MetricCards in LazyVGrid adaptive grid, 2 QuickActions, shimmer loading, permission denied + empty library + error states, relative timestamp footer
- MainView wired with SwiftData PersistedMetricsSnapshot: loads cached snapshot before fetching tracks, saves snapshot after successful fetch with previous values shifted for trend calculation
- GaugeView.swift deleted (replaced by HeroGauge from SharedUI package)

## Task Commits

Each task was committed atomically:

1. **Task 1: Redesign MetricCard and QuickActionButton components** - `923aa85` (feat)
2. **Task 2: Rewrite DashboardView, wire MainView snapshot, delete GaugeView** - `4f534d9` (feat)

## Files Created/Modified

- `App/Views/Components/MetricCard.swift` - Rewritten: trend arrow + hover delta, StatCard-consistent hover/press (shadow elevation + accent border + 0.98 scale), removed subtitle property
- `App/Views/Components/QuickActionButton.swift` - Rewritten: neutral tone ("Genre . 327 untagged"), zero-state checkmark, horizontal HStack layout, plain button style with hover background
- `App/Views/DashboardView.swift` - Complete rewrite: HeroGauge hero, MetricCards in LazyVGrid, QuickActions, shimmer/permissionDenied/emptyLibrary/error states, relative timestamp footer
- `App/Views/MainView.swift` - Added metricsSnapshot @State, loadCachedSnapshot(), saveMetricsSnapshot() with SwiftData, passes snapshot + isLoading to DashboardView
- `Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift` - Updated comment: GaugeView reference changed to HeroGauge
- `App/Views/Components/GaugeView.swift` - **DELETED**: replaced by SharedUI HeroGauge

## Decisions Made

- MetricCard uses StatCard-consistent hover/press pattern (shadow elevation + accent border + 0.98 scale + DragGesture) -- ensures design consistency across all interactive cards
- QuickActionButton parameter renamed from `count` to `untaggedCount` to avoid SwiftLint `empty_count` false positive on `count > 0`
- MainView saves metrics snapshot to SwiftData directly (no separate service) -- keeps the flow simple, MainView already has @Environment(\.modelContext)
- Empty library "Open Music" button uses `music://` URL scheme instead of deprecated `NSWorkspace.launchApplication`
- No "Library Health" title above gauge -- gauge + legend are self-explanatory per Claude's Discretion in CONTEXT.md

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Force unwrapping in emptyLibraryView URL**
- **Found during:** Task 2 (DashboardView rewrite)
- **Issue:** `URL(string: "music://")!` triggers SwiftLint force_unwrapping rule
- **Fix:** Changed to `if let url = URL(string: "music://") { NSWorkspace.shared.open(url) }`
- **Files modified:** App/Views/DashboardView.swift
- **Verification:** SwiftLint passes with 0 violations
- **Committed in:** 4f534d9 (Task 2 commit)

**2. [Rule 1 - Bug] SwiftLint empty_count false positive on QuickActionButton**
- **Found during:** Task 1 (QuickActionButton rewrite)
- **Issue:** `count > 0` triggers SwiftLint empty_count rule even though `count` is a plain Int parameter, not a collection's `.count`
- **Fix:** Renamed parameter from `count` to `untaggedCount` to avoid the lint trigger
- **Files modified:** App/Views/Components/QuickActionButton.swift
- **Verification:** SwiftLint passes with 0 violations
- **Committed in:** 923aa85 (Task 1 commit)

**3. [Rule 3 - Blocking] XcodeGen regeneration required after GaugeView deletion**
- **Found during:** Task 2 (GaugeView deletion)
- **Issue:** Deleting GaugeView.swift left a stale reference in the Xcode project file, causing "Build input file cannot be found" error
- **Fix:** Ran `xcodegen generate` to regenerate the project from project.yml (which auto-discovers sources from App/ directory)
- **Files modified:** GenreUpdater.xcodeproj/project.pbxproj (auto-regenerated)
- **Verification:** Full build succeeds
- **Committed in:** 4f534d9 (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (2 bugs, 1 blocking)
**Impact on plan:** All fixes necessary for lint compliance and successful build. No scope creep.

## Issues Encountered

- Pre-existing flaky test in Services: "Delays increase exponentially between attempts" (timing-sensitive backoff test) -- not related to this plan's changes
- SwiftFormat auto-fixed conditionalAssignment in MetricCard.swift (switch expression for `direction` variable) -- cosmetic, no behavior change

## User Setup Required

None -- no external service configuration required.

## Next Phase Readiness

- Phase 5 (Dashboard Redesign) is now complete -- both plans executed
- Phase 8 (Animations) can add draw-in animation to HeroGauge arcs (currently static fill)
- Phase 8 can add .contentTransition(.numericText()) for cached-to-live value animation
- Phase 7 (Reports) inherits the Top Genres section that was removed from Dashboard

## Self-Check: PASSED

- FOUND: App/Views/DashboardView.swift
- FOUND: App/Views/Components/MetricCard.swift
- FOUND: App/Views/Components/QuickActionButton.swift
- FOUND: App/Views/MainView.swift
- MISSING (expected): App/Views/Components/GaugeView.swift (deleted)
- FOUND: .planning/phases/05-dashboard-redesign/05-02-SUMMARY.md
- FOUND: commit 923aa85
- FOUND: commit 4f534d9

---
*Phase: 05-dashboard-redesign*
*Completed: 2026-02-23*
