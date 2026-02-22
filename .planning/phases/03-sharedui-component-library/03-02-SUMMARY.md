---
phase: 03-sharedui-component-library
plan: 02
subsystem: ui
tags: [swiftui, list-row, section-index, hover, press, selected, sf-mono, drag-gesture]

requires:
  - phase: 01-design-system-foundation
    provides: "DesignTokens (Spacing, Radius, AppFont, Motion, Shadow), AyuColors"
  - phase: 03-sharedui-component-library plan 01
    provides: "Components directory, FilterChip/StatCard interaction patterns"
provides:
  - "ArtistListRow — artist name with SF Mono album/track count badges"
  - "AlbumListRow — album title with optional genre pill and year"
  - "SectionIndexBar — smart-filtered vertical index with drag-to-scroll"
  - "Shared hover/press/selected interaction trio pattern for list rows"
affects: [06-views-polish, browse-screen, artist-list, album-list]

tech-stack:
  added: []
  patterns:
    - "Leading accent bar + tinted background for hover/selected states"
    - "simultaneousGesture DragGesture for press detection without blocking parent tap"
    - "SF Mono (.system(.caption, design: .monospaced)) for column-aligned count badges"
    - "Smart-mode section index: only letters with content, not full A-Z"

key-files:
  created:
    - Packages/SharedUI/Sources/SharedUI/Components/ArtistListRow.swift
    - Packages/SharedUI/Sources/SharedUI/Components/AlbumListRow.swift
    - Packages/SharedUI/Sources/SharedUI/Components/SectionIndexBar.swift
  modified:
    - CLAUDE.md

key-decisions:
  - "Color-based background via computed property returning Color (not ShapeStyle) for type-safe row backgrounds"
  - "SectionIndexBar uses Spacing.xxs vertical padding offset in Y calculation for accurate letter hit targets"
  - "Genre badge uses AppFont.caption (semantic) vs count badges using .system(.caption, design: .monospaced) (numeric alignment)"

patterns-established:
  - "List row interaction trio: hover accent bar + press 0.98x scale + selected tinted background"
  - "SectionIndexBar placement: outside List in HStack, not inside scroll view"
  - ".contentShape(.rect) on all interactive rows for macOS 15 scroll fix"

requirements-completed: [DSYS-03]

duration: 3min
completed: 2026-02-22
---

# Phase 03 Plan 02: List Rows and Index Bar Summary

**ArtistListRow and AlbumListRow with hover/press/selected interaction trio, plus SectionIndexBar with smart-filtered drag-to-scroll navigation for Browse screen**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-22T14:13:47Z
- **Completed:** 2026-02-22T14:16:43Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- ArtistListRow with SF Mono album/track count badges and leading accent bar hover state
- AlbumListRow with optional genre pill, optional year, and identical interaction pattern
- SectionIndexBar with smart-filtered letters and drag-to-scroll gesture calling onLetterSelected
- All three components use .contentShape(.rect), .focusable(), full accessibility labels, and #Preview blocks

## Task Commits

Both tasks combined into one commit (docs-sync hook requires CLAUDE.md staged with Swift files):

1. **Task 1: Create ArtistListRow and AlbumListRow** - `f30f084` (feat)
2. **Task 2: Create SectionIndexBar** - `f30f084` (feat, same commit)

**Plan metadata:** (pending) (docs: complete plan)

## Files Created/Modified
- `Packages/SharedUI/Sources/SharedUI/Components/ArtistListRow.swift` - Artist row with name, album count badge, track count badge, hover/press/selected states
- `Packages/SharedUI/Sources/SharedUI/Components/AlbumListRow.swift` - Album row with title, optional genre pill, optional year, identical interaction states
- `Packages/SharedUI/Sources/SharedUI/Components/SectionIndexBar.swift` - Vertical alphabetical index bar with drag gesture, smart-filtered letters, consumer guidance docs
- `CLAUDE.md` - Added SharedUI List Row Interaction pattern to Coding Patterns section

## Decisions Made
- Used computed `Color` property for row backgrounds instead of `@ViewBuilder` — cleaner since `Color.opacity()` returns `Color` in SwiftUI
- SectionIndexBar accounts for vertical padding offset when calculating letter index from drag Y position
- Genre badge uses semantic `AppFont.caption` while count badges use `.system(.caption, design: .monospaced)` for column alignment

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- Pre-commit hook requires `codex-commit-style-marker` before commits and enforces 55-char line limit — accommodated by using shorter commit messages

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All Browse screen building blocks are ready (ArtistListRow, AlbumListRow, SectionIndexBar)
- Phase 6 can consume these directly in ScrollViewReader + List pattern (documented in SectionIndexBar source)
- Plan 03-03 (remaining SharedUI components) can proceed independently

## Self-Check: PASSED

- [x] ArtistListRow.swift exists
- [x] AlbumListRow.swift exists
- [x] SectionIndexBar.swift exists
- [x] 03-02-SUMMARY.md exists
- [x] Commit f30f084 exists in git log

---
*Phase: 03-sharedui-component-library*
*Completed: 2026-02-22*
