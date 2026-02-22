# GenreUpdater — UI/UX Redesign

## What This Is

A macOS app that automatically updates genre and year tags in Apple Music libraries using MusicBrainz, Discogs, and Apple Music APIs. The backend (algorithms, APIs, persistence, subscriptions) is complete through Phase 6. This milestone focuses on a full UI/UX redesign — replacing the prototype views with a crafted, Spotify/Doppler-inspired interface.

## Core Value

The app must feel fast, intuitive, and satisfying to use on a 38K+ track library — users should never feel lost, never see empty states, and always understand what the app can do for their music collection.

## Requirements

### Validated

- ✓ MusicKit library reading with MusicAuthorization — Phase 1
- ✓ AppleScript writes to Music.app via NSUserAppleScriptTask — Phase 1
- ✓ Core genre determination (GenreDeterminator, rule-based matching) — Phase 3
- ✓ Core year determination (YearScorer, YearValidator, YearDeterminator) — Phase 3
- ✓ Artist/Album matching and normalization — Phase 3
- ✓ MusicBrainz, Discogs, Apple Music API clients with rate limiting — Phase 4
- ✓ APIOrchestrator fan-out with confidence scoring — Phase 4
- ✓ GRDB API response cache with bulk operations — Phase 4
- ✓ SwiftData track state persistence — Phase 2A
- ✓ StoreKit 2 subscriptions (free/weekPass/pro) with FeatureGate — Phase 2B
- ✓ UpdateCoordinator with single/batch/dry-run modes — Phase 5
- ✓ BatchProcessor with AsyncStream progress and CheckpointManager — Phase 5
- ✓ UndoCoordinator with change log — Phase 5
- ✓ ChangePreviewPipeline for proposed changes review — Phase 5
- ✓ LibrarySyncService for library delta scanning — Phase 5
- ✓ Input sanitization (sanitizeScriptCode vs escapeStringValue) — Phase 1.5
- ✓ Structured logging with privacy levels — Phase 1
- ✓ 734 unit tests (Core 418, Services 316) with CI coverage enforcement — Phase 7
- ✓ Basic SwiftUI views (Dashboard, Browse, Update, Reports, Settings) — Phase 6

### Active

**Dashboard:**
- [ ] Half-circle gauge as hero element — large, interactive, showing library track count
- [ ] Gauge layers visualize metadata health: genre %, year %, consistency
- [ ] Toggle-able gauge overlays (genre distribution, year distribution, etc.)
- [ ] Metrics ring around gauge — key library stats for quick comprehension
- [ ] Instant data on launch — cache library metrics, show cached on start, delta-scan in background
- [ ] Loading state hidden behind animations (skeleton / shimmer), never show "0 tracks"
- [ ] Smart quick actions that reflect actual library state (not generic buttons)

**Browse:**
- [ ] Artist → Album → Track drill-down navigation
- [ ] Select entire artist for batch processing (checkbox/toggle at artist level)
- [ ] Shift-select for ranges, Cmd-click for individual
- [ ] Smart filters: genre, year, tag status (missing/present), recently added
- [ ] Search with instant results across artists, albums, tracks
- [ ] Proper alphabet section headers with sticky behavior
- [ ] Track count badges with visual weight (not just text)
- [ ] Duplicate artist detection visual indicators (e.g., "2CELLOS" vs "2Cellos")

**Update:**
- [ ] Clear mode selection with visual preview of scope (Selected Tracks / Full Library / Smart Filter)
- [ ] Inline preview of changes before applying
- [ ] Real-time batch progress with per-track status
- [ ] Confidence visualization per proposed change
- [ ] Smart filter builder (genre = empty, year < 1990, added this week)

**Reports:**
- [ ] Meaningful empty state — not "No Data", but guidance on what to do
- [ ] Genre distribution chart (horizontal bars, sorted by count)
- [ ] Year timeline (histogram or sparkline)
- [ ] Change history with undo affordance
- [ ] Export functionality (CSV)

**Design System:**
- [ ] Custom dark + light theme (auto-switch by system, manual override)
- [ ] Spotify/Doppler-inspired visual language — dark backgrounds, bright accents, content-first
- [ ] Consistent spacing scale, typography scale, corner radius scale
- [ ] Hover states, press states, focus states on all interactive elements
- [ ] Smooth transitions between views (no jarring cuts)
- [ ] Information density tuned for macOS (not iOS-sparse, not spreadsheet-dense)

**Navigation:**
- [ ] Sidebar with clear active state and grouping
- [ ] Dashboard occupies full content area (no useless "Select a Track" panel)
- [ ] Detail panel only when relevant (Browse with selected track)
- [ ] Keyboard shortcuts for all main actions (Cmd+1-4 navigation, Cmd+Return to start update)

### Out of Scope

- iOS/iPadOS support — macOS only, optimize for mouse+keyboard
- Custom icon design — use SF Symbols throughout
- Onboarding redesign — focus on core screens first
- Localization — English only for this milestone
- Accessibility overhaul — maintain VoiceOver basics but don't optimize
- New backend features — use existing Services layer as-is

## Context

**Current state:** Phases 1-6 are complete. The backend is solid — algorithms, APIs, persistence, subscriptions all work with 734 tests. But the UI was built as a prototype (Phase 6) and never polished. The user describes it as "terrible" on both UI and UX fronts.

**Key problems observed (from screenshots):**
1. Dashboard shows "0 tracks" and empty metrics on first launch — no caching, no loading state
2. Gauge is small, non-interactive, wastes space in a three-column layout
3. Quick Action buttons have text wrapping ("Up-date Gen-res") — broken layout
4. Browse is a flat list of 2,271 artists — no drill-down, no batch select, no grouping
5. Right panel shows "Select a Track" placeholder on screens where it makes no sense (Dashboard, Update)
6. Reports is three "No Data" blocks — depressing empty state
7. Metric cards are tiny, uneven, poorly aligned
8. No hover states, no transitions, no interactive feedback anywhere
9. Information density is wrong — too empty on Dashboard, too dense on Browse

**Existing infrastructure:**
- SharedUI package with DesignTokens (Ayu color palette, Spacing, Radius, AppFont)
- NavigationSplitView with sidebar
- LibrarySyncService already handles delta scanning
- Cached metrics should be possible via SwiftData or GRDB

**Technical constraints:**
- Must work with existing Services layer (actors, async/await)
- Must maintain @Observable + @MainActor view model pattern
- SwiftUI on macOS 15+ — no backward compat concerns
- Must pass SwiftLint --strict and SwiftFormat

**User profile:** Power user with 38,085 tracks. Values speed, information density, and batch operations. Spotify/Doppler aesthetic preference — dark theme with bright accents, content-first design.

## Constraints

- **Platform**: macOS 15.0+ only, App Store distribution (sandboxed)
- **Framework**: SwiftUI only — no AppKit except where SwiftUI lacks capability
- **Architecture**: Must use existing App → Services → Core layer structure
- **Approach**: Incremental — one screen at a time, app always functional
- **Style**: Custom macOS, NOT native Apple look — Spotify/Doppler inspiration
- **Theme**: Dark + Light, auto-detect system preference with manual override
- **Performance**: Must handle 38K+ tracks without lag in Browse/Dashboard

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Custom macOS style over native | User wants Spotify/Doppler feel, not system look | — Pending |
| Half-circle gauge as Dashboard hero | User's vision — large, interactive, information-rich | — Pending |
| Dark + Light dual theme | Users expect system-matching theme support | — Pending |
| Incremental redesign approach | Always-working app, one screen at a time | — Pending |
| Drill-down + Smart Filters for selection | User needs both browse-by-artist AND filter-by-criteria | — Pending |
| Cache metrics for instant Dashboard | "0 tracks" on launch is unacceptable UX | — Pending |
| Reuse LibrarySyncService for delta | Existing delta scanning mechanism, extend for dashboard metrics | — Pending |

---
*Last updated: 2026-02-22 after initialization*
