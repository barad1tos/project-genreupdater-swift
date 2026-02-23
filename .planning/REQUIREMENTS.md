# Requirements: GenreUpdater — UI/UX Redesign

**Defined:** 2026-02-22
**Core Value:** The app must feel fast, intuitive, and satisfying to use on a 38K+ track library — users should never feel lost, never see empty states, and always understand what the app can do for their music collection.

## v1 Requirements

Requirements for the UI/UX redesign milestone. Each maps to roadmap phases.

### Design System

- [x] **DSYS-01**: User can switch between dark and light themes (auto-detect system preference with manual override via Settings)
- [x] **DSYS-02**: All UI components use extended design tokens including Shadow and Motion enums alongside existing Spacing/Radius/AppFont
- [x] **DSYS-03**: All interactive elements show hover, press, and focus states
- [ ] **DSYS-04**: View transitions between screens are smooth with no jarring cuts
- [x] **DSYS-05**: Ayu/Ayu Mirage color palette is preserved and extended; light-mode contrast meets WCAG AA (≥4.5:1)

### Navigation

- [x] **NAV-01**: Sidebar has Ayu dark background with matchedGeometryEffect sliding active indicator
- [x] **NAV-02**: Dashboard, Update, and Reports screens use doubleColumn layout (no spurious "Select a Track" panel)
- [x] **NAV-03**: App enforces minimum window width of 900pt to prevent layout collapse

### Dashboard

- [x] **DASH-01**: Dashboard displays a half-circle gauge as the hero element showing library track count with genre/year/consistency arc layers
- [x] **DASH-02**: Dashboard shows cached metrics instantly on launch from SwiftData snapshot, then updates to live metrics via background delta-scan — never displays "0 tracks"
- [x] **DASH-03**: First launch uses skeleton/shimmer animations (SwiftUI-Shimmer) to indicate loading instead of empty values
- [x] **DASH-04**: Quick action buttons reflect actual library state with live counts (e.g. "327 tracks missing genre — fix now")

### Browse

- [ ] **BRWS-01**: User can navigate Artist → Album → Track hierarchy with collapsible sections
- [ ] **BRWS-02**: User can select multiple items via Shift-click (range) and Cmd-click (individual) with a persistent bulk-action bar when selection count > 0
- [ ] **BRWS-03**: User can search across artists, albums, and tracks with 300ms debounced filtering computed off the main thread
- [ ] **BRWS-04**: Browse displays alphabetical section headers with sticky behavior and track count badges per artist/album

### Update

- [ ] **UPDT-01**: User sees a clear mode selection UI with visual preview of scope (Selected Tracks / Full Library)
- [ ] **UPDT-02**: User can preview proposed changes inline (before/after diff) via ChangePreviewPipeline before applying
- [ ] **UPDT-03**: User sees real-time batch progress with per-track status from BatchProcessor AsyncStream
- [ ] **UPDT-04**: Each proposed change displays a confidence badge showing determination confidence level
- [ ] **UPDT-05**: Dry-run is the default update mode; user must explicitly opt into live writes (protects library from accidental changes)

### Reports

- [ ] **RPTS-01**: Reports shows meaningful empty states with guidance CTA ("Run your first scan to see results") instead of "No Data"
- [ ] **RPTS-02**: Reports displays genre distribution as a horizontal bar chart sorted by count (Swift Charts)
- [ ] **RPTS-03**: Reports displays year distribution as a histogram or sparkline timeline (Swift Charts)
- [ ] **RPTS-04**: Reports shows change history log with undo affordance per entry via UndoCoordinator

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Navigation

- **NAV-04**: Keyboard shortcuts Cmd+1-4 for screen navigation, Cmd+Return to start update

### Dashboard

- **DASH-05**: Toggle-able gauge overlays (genre distribution, year distribution layers)

### Browse

- **BRWS-05**: Smart filter builder with chip-style predicate composer (genre = empty, year < 1990, added this week)
- **BRWS-06**: Duplicate artist detection visual indicators (e.g. "2CELLOS" vs "2Cellos")

### Reports

- **RPTS-05**: CSV export functionality for reports data

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| iOS/iPadOS support | macOS only — optimize for mouse+keyboard |
| Custom icon design | Use SF Symbols throughout |
| Onboarding redesign | Focus on core screens first |
| Localization | English only for this milestone |
| Accessibility overhaul | Maintain VoiceOver basics but don't optimize |
| New backend features | Use existing Services layer as-is |
| Per-track manual genre selector | Overly complex, defeats automation purpose |
| Streaming/playback integration | Out of scope — this is a metadata management tool |
| Global sidebar collapse | Sidebar always visible on macOS |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| DSYS-01 | Phase 2 | Complete |
| DSYS-02 | Phase 1 | Complete |
| DSYS-03 | Phase 3 | Complete |
| DSYS-04 | Phase 8 | Pending |
| DSYS-05 | Phase 1 | Complete |
| NAV-01 | Phase 4 | Complete |
| NAV-02 | Phase 4 | Complete |
| NAV-03 | Phase 4 | Complete |
| DASH-01 | Phase 5 | Complete |
| DASH-02 | Phase 5 | Complete |
| DASH-03 | Phase 5 | Complete |
| DASH-04 | Phase 5 | Complete |
| BRWS-01 | Phase 6 | Pending |
| BRWS-02 | Phase 6 | Pending |
| BRWS-03 | Phase 6 | Pending |
| BRWS-04 | Phase 6 | Pending |
| UPDT-01 | Phase 7 | Pending |
| UPDT-02 | Phase 7 | Pending |
| UPDT-03 | Phase 7 | Pending |
| UPDT-04 | Phase 7 | Pending |
| UPDT-05 | Phase 7 | Pending |
| RPTS-01 | Phase 7 | Pending |
| RPTS-02 | Phase 7 | Pending |
| RPTS-03 | Phase 7 | Pending |
| RPTS-04 | Phase 7 | Pending |

**Coverage:**
- v1 requirements: 25 total
- Mapped to phases: 25
- Unmapped: 0 ✓

---
*Requirements defined: 2026-02-22*
*Last updated: 2026-02-23 after milestone audit gap closure*
