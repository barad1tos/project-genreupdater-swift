---
phase: 07-update-reports-polish
plan: 02
subsystem: ui
tags: [swiftui, update-screen, composable-views, streaming-progress, preview, ayu]

requires:
  - phase: 07-update-reports-polish
    provides: TrackProcessingStatus, per-track status dictionary, scope preview, dry-run default ON, @State ViewModel persistence
provides:
  - UpdateConfigSection with mode picker, scope preview card, options, confidence slider, dry-run toggle
  - UpdatePreviewSection with grouped-by-artist change list, per-group Accept/Reject, ConfidenceBadge per row
  - UpdateStreamingSection with compact progress bar, per-track status rows, auto-scroll, cancel
  - UpdateDoneSection with summary card (updated/failed counts), final status rows, reset
  - Thin UpdateWorkflowView router composing sub-views by WorkflowPhase
affects: [07-03-reports-polish, 07-04-reports-polish]

tech-stack:
  added: []
  patterns:
    - "Composable sub-view pattern: focused section files receiving @Bindable ViewModel"
    - "Compact progress bar via GeometryReader percentage-width Capsule"
    - "ScrollViewReader + onScrollPhaseChange for auto-scroll with user scroll detection"

key-files:
  created:
    - App/Views/Update/UpdateConfigSection.swift
    - App/Views/Update/UpdatePreviewSection.swift
    - App/Views/Update/UpdateStreamingSection.swift
    - App/Views/Update/UpdateDoneSection.swift
  modified:
    - App/Views/UpdateWorkflowView.swift

key-decisions:
  - "Config section visible during scanning/applying phases so user sees their choices"
  - "Grouped preview uses local Dictionary(grouping:) instead of injecting ChangePreviewPipeline to keep Views independent of Services"
  - "onScrollPhaseChange (macOS 15+) for user scroll detection instead of custom gesture recognizer"
  - "Paused and error views kept inline in router (simple, under 30 lines each)"

patterns-established:
  - "Composable sub-views: each section receives @Bindable ViewModel, owns its own layout"
  - "Compact progress bar: GeometryReader width * fraction with Capsule shape"

requirements-completed: [UPDT-01, UPDT-02, UPDT-03, UPDT-04, UPDT-05]

duration: 9min
completed: 2026-02-23
---

# Phase 07 Plan 02: Update Screen Rewrite Summary

**Composable Update screen with mode/scope config, grouped preview with per-group accept/reject and ConfidenceBadge, streaming per-track progress rows with auto-scroll, and summary done card**

## Performance

- **Duration:** 9 min
- **Started:** 2026-02-23T21:24:23Z
- **Completed:** 2026-02-23T21:33:27Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Four focused Update sub-views replace the monolithic inline implementations (799 lines across 4 files)
- UpdateConfigSection shows mode picker, scope preview card (track/artist counts), options with prominent dry-run toggle, and confidence slider
- UpdatePreviewSection groups proposed changes by artist with per-group Accept/Reject buttons and ConfidenceBadge on every row
- UpdateStreamingSection shows compact progress bar (N/total with accent Capsule), per-track status indicators (queued/analyzing/writing/done/failed/skipped), and auto-scroll that pauses on user scroll
- UpdateDoneSection presents a summary card with updated/failed counts and scrollable final status rows
- UpdateWorkflowView reduced from 413 lines to 124 lines as a thin composition router

## Task Commits

Each task was committed atomically:

1. **Task 1: Create Update sub-view files** - `2cb6e74` (feat)
2. **Task 2: Rewrite UpdateWorkflowView as thin router** - `f4b3d9b` (refactor)

## Files Created/Modified
- `App/Views/Update/UpdateConfigSection.swift` - Mode picker, scope preview card, options card, dry-run toggle, confidence slider, start button (185 lines)
- `App/Views/Update/UpdatePreviewSection.swift` - Grouped change list with per-group Accept/Reject, ConfidenceBadge, action bar (199 lines)
- `App/Views/Update/UpdateStreamingSection.swift` - Compact progress bar, streaming track rows with status indicators, auto-scroll, cancel bar (232 lines)
- `App/Views/Update/UpdateDoneSection.swift` - Summary card with counts, final status rows, Start New Update button (183 lines)
- `App/Views/UpdateWorkflowView.swift` - Thin router composing sub-views by phase, paused/error views kept inline (124 lines)

## Decisions Made
- Config section stays visible during scanning and applying phases so the user can see their chosen mode and options while processing occurs
- Grouped preview computes grouping locally via Dictionary(grouping:) rather than injecting ChangePreviewPipeline -- keeps Views independent of Services package
- Used onScrollPhaseChange (macOS 15+ API) for detecting user scroll in streaming section instead of a custom DragGesture approach -- cleaner and more reliable
- Paused and error views kept inline in the router (small enough not to warrant separate files)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Update screen fully composed and building -- ready for visual verification
- All UPDT requirements addressed (mode selection, preview, streaming progress, confidence badges, dry-run default)
- Reports polish (Plans 03 and 04) can proceed independently

## Self-Check: PASSED

- All 6 files verified (4 created + 1 modified + 1 SUMMARY)
- Both commits verified (2cb6e74, f4b3d9b)
- SwiftLint --strict passes for all 5 Swift files (0 violations)
- xcodebuild compiles cleanly

---
*Phase: 07-update-reports-polish*
*Completed: 2026-02-23*
