# Roadmap: GenreUpdater — UI/UX Redesign

## Overview

The backend is complete through Phase 6 (734 tests, all algorithms, APIs, persistence, and subscriptions working). This milestone replaces the prototype views with a crafted, Spotify/Doppler-inspired interface. The build order is strictly dependency-driven: design tokens before components, components before screens, navigation shell before screen work, Dashboard before Browse (more architectural deps), animations last (requires stable layout). Each phase delivers a coherent, independently verifiable capability.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Design System Foundation** - Extend DesignTokens with Shadow/Motion enums and fix Ayu light-mode contrast to WCAG AA
- [ ] **Phase 2: Theme Switching** - Wire AppTheme enum with @AppStorage, preferredColorScheme, and NSApp.appearance sync
- [ ] **Phase 3: SharedUI Component Library** - Build HeroGauge, StatCard, ArtistListRow, AlbumListRow, FilterChip, SectionIndexBar with hover/press/focus states
- [ ] **Phase 4: Navigation Shell** - Restyle sidebar with Ayu dark background and matchedGeometryEffect indicator; fix column visibility for non-Browse screens
- [ ] **Phase 5: Dashboard Redesign** - Half-circle HeroGauge hero, cached-first metrics loading, smart quick-actions with live counts, skeleton shimmer
- [ ] **Phase 6: Browse Redesign** - Artist/Album/Track drill-down with List-backed multi-select, debounced off-main-thread search, sticky section headers
- [ ] **Phase 7: Update and Reports Polish** - Mode selector UI, per-track progress rows, Reports charts and empty states, change history with undo
- [ ] **Phase 8: Animations and Final Polish** - Content transitions between screens, entrance animations on Dashboard, hover/press states audit across all views

## Phase Details

### Phase 1: Design System Foundation
**Goal**: The SharedUI token layer is complete and correct — every subsequent phase reads exact values for color, shadow, spacing, and motion without guessing
**Depends on**: Nothing (first phase)
**Requirements**: DSYS-02, DSYS-05
**Success Criteria** (what must be TRUE):
  1. Shadow and Motion enums exist in DesignTokens alongside the existing Spacing, Radius, and AppFont enums
  2. Ayu light-mode foreground colors pass WCAG AA contrast ratio (>=4.5:1) against the light background — verifiable with any contrast checker
  3. Minimum window width of 900pt is enforced — dragging the window narrower snaps back or stops at 900pt
**Plans**: TBD

### Phase 2: Theme Switching
**Goal**: Users can switch between dark and light themes and the preference persists across launches; all surfaces including AppKit sheets honor the selected theme
**Depends on**: Phase 1
**Requirements**: DSYS-01
**Success Criteria** (what must be TRUE):
  1. Settings exposes a theme picker with Dark, Light, and System options
  2. Selecting Dark or Light immediately updates the entire app — sidebar, content area, sheets, and date pickers all change color mode
  3. The chosen theme persists after quitting and relaunching the app
  4. When set to System, the app tracks the system appearance change in real time without a restart
**Plans**: TBD

### Phase 3: SharedUI Component Library
**Goal**: All reusable UI components exist as independently previewable SwiftUI views with correct hover, press, and focus states so screen-level work never blocks on missing primitives
**Depends on**: Phase 2
**Requirements**: DSYS-03
**Success Criteria** (what must be TRUE):
  1. HeroGauge renders a half-circle arc and accepts Double values for genre, year, and consistency layers without requiring access to Track data
  2. ArtistListRow and AlbumListRow show a distinct background highlight on hover using .onHover
  3. FilterChip, StatCard, and SectionIndexBar render correctly in both dark and light theme previews
  4. All interactive components show a visual press state (scale or opacity change) on mouse-down
  5. SwiftUI-Shimmer is added to the SharedUI Package.swift and a ShimmerPlaceholder view is usable from App target
**Plans**: TBD

### Phase 4: Navigation Shell
**Goal**: The sidebar is visually polished and the column layout is correct for every screen — Dashboard, Update, and Reports never show a spurious "Select a Track" detail column
**Depends on**: Phase 3
**Requirements**: NAV-01, NAV-02, NAV-03
**Success Criteria** (what must be TRUE):
  1. Sidebar renders with an Ayu dark background in both light and dark system themes
  2. The active sidebar item has a sliding highlight that moves with matchedGeometryEffect when switching screens
  3. Navigating to Dashboard, Update, or Reports shows a two-column layout — no detail panel placeholder appears
  4. Navigating to Browse with a selected track reveals the detail panel; deselecting collapses it back
**Plans**: TBD

### Phase 5: Dashboard Redesign
**Goal**: Dashboard is a compelling first impression — it shows real library data instantly on every launch, never displays "0 tracks", and gives users one-click access to the most impactful actions for their specific library
**Depends on**: Phase 4
**Requirements**: DASH-01, DASH-02, DASH-03, DASH-04
**Success Criteria** (what must be TRUE):
  1. A large half-circle gauge is the visual centerpiece of the Dashboard — it shows the library track count and has distinct arc segments for genre coverage, year coverage, and consistency
  2. Launching the app shows cached library metrics immediately (never "0 tracks"), even before MusicKit finishes loading
  3. On first launch (no cache), skeleton shimmer placeholders fill the gauge and metric cards — no empty numeric values appear
  4. Quick action buttons display live counts derived from actual library state (e.g. "327 tracks missing genre — Fix Now") and those counts update after a background scan completes
**Plans**: TBD

### Phase 6: Browse Redesign
**Goal**: Users can navigate 38,000+ tracks efficiently — drill into artist/album hierarchies, select multiple items for batch processing, and search with instant results — without any lag or layout collapse
**Depends on**: Phase 4
**Requirements**: BRWS-01, BRWS-02, BRWS-03, BRWS-04
**Success Criteria** (what must be TRUE):
  1. The artist list loads and scrolls smoothly at 2,271 artists — clicking an artist expands its albums; clicking an album shows its tracks (no separate navigation push required)
  2. Shift-clicking two artists selects the full range; Cmd-clicking adds or removes individual artists; when any items are selected a bulk-action bar appears at the bottom of the list and persists while scrolling
  3. Typing in the search field filters artists, albums, and tracks within 300ms with computation running off the main thread — the UI remains responsive while filtering
  4. Artist rows display sticky alphabetical section headers as the user scrolls; each artist row shows a track count badge
**Plans**: TBD

### Phase 7: Update and Reports Polish
**Goal**: The Update and Reports screens are complete — Update gives users clear control over what will change and real-time feedback during execution; Reports surfaces meaningful library insights instead of empty charts
**Depends on**: Phase 5
**Requirements**: UPDT-01, UPDT-02, UPDT-03, UPDT-04, UPDT-05, RPTS-01, RPTS-02, RPTS-03, RPTS-04
**Success Criteria** (what must be TRUE):
  1. Update mode selection (Selected Tracks vs. Full Library) is visually distinct with scope preview; dry-run is the default and a clear opt-in toggle enables live writes
  2. Clicking "Preview Changes" shows a before/after diff for each track, with a confidence badge on every proposed change, before any write occurs
  3. During an active batch update, each track row shows its real-time status (queued, processing, updated, failed) streamed from BatchProcessor
  4. Reports displays a horizontal genre bar chart and a year histogram using Swift Charts data — both charts render with actual data after at least one scan has run
  5. Reports empty state shows a specific guidance CTA ("Run your first scan to see results") — the phrase "No Data" does not appear anywhere in Reports
  6. The change history log shows each past change with an Undo button that reverses the change via UndoCoordinator
**Plans**: TBD

### Phase 8: Animations and Final Polish
**Goal**: The app feels alive and responsive — every screen transition is smooth, Dashboard metrics animate in on load, and all interactive elements provide immediate tactile feedback
**Depends on**: Phase 7
**Requirements**: DSYS-04
**Success Criteria** (what must be TRUE):
  1. Switching between sidebar items produces a smooth cross-fade content transition — no jarring instant cuts between screens
  2. Dashboard metric values animate from cached to live numbers using .contentTransition(.numericText()) when the background scan completes
  3. All list rows (Browse artists, Update track rows, Reports change log) show a hover highlight that appears and disappears without lag
  4. Interactive buttons and action items show a visible press state (scale or opacity) on mouse-down across all screens
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute sequentially: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Design System Foundation | 0/TBD | Not started | - |
| 2. Theme Switching | 0/TBD | Not started | - |
| 3. SharedUI Component Library | 0/TBD | Not started | - |
| 4. Navigation Shell | 0/TBD | Not started | - |
| 5. Dashboard Redesign | 0/TBD | Not started | - |
| 6. Browse Redesign | 0/TBD | Not started | - |
| 7. Update and Reports Polish | 0/TBD | Not started | - |
| 8. Animations and Final Polish | 0/TBD | Not started | - |
