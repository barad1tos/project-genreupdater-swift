# Feature Landscape

**Domain:** macOS music library management app (metadata batch editor)
**Researched:** 2026-02-22
**Overall confidence:** HIGH (patterns from Spotify/Doppler/Roon/iTunes/Linear verified via multiple sources)

---

## Context

GenreUpdater is a power-user tool for batch-updating genre and year tags in Apple Music libraries.
The backend is complete through Phase 6. This document maps the UI/UX feature landscape for the
redesign milestone targeting a Spotify/Doppler-inspired interface on macOS 15+.

User profile: 38,085 tracks, values speed and batch operations, prefers dark aesthetic with bright accents.

---

## Table Stakes

Features users expect. Missing any of these and the app feels broken or unfinished.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Instant data on launch | "0 tracks" on first screen-load kills trust. Roon, Spotify, and Music.app all show cached/stale data immediately, then update in background. | Medium | LibrarySyncService delta scan runs in background; Dashboard shows cached metrics from SwiftData/GRDB on first render. |
| Non-blocking loading states | Users distinguish "loading" from "empty". Skeleton/shimmer rows signal that data is coming, not absent. | Low | Redacted rows with shimmer animation while MusicKit authorization completes and first scan runs. |
| Artist → Album → Track drill-down | Every music app (Doppler, iTunes, Roon, Music.app) uses 3-level hierarchy as the primary browse model. Flat artist list is unusable at 2,271 artists. | Medium | Requires grouping cached data already loaded from MusicKit; SwiftUI List with Section headers. |
| Sticky alpha section headers | Music.app, Contacts, and every macOS list with alphabetical content use sticky section headers + alphabet index. Users of large libraries depend on this. | Medium | Native SwiftUI section pinning with List; performance tested for 38K tracks. |
| Shift-click range selection | macOS HIG standard for lists. Finder, Music.app, Mail all use it. Power users expect it without thinking. | Medium | SwiftUI doesn't expose this natively; requires custom gesture tracking on List rows. |
| Cmd-click individual multi-select | Same HIG expectation as shift-click. Standard macOS selection modifier. | Low | Can be layered on top of List selection with a custom selection binding. |
| Persistent bulk-action bar | When items are selected, the action bar must remain visible while scrolling. Eleken UX research: "must stay persistent while users scroll." | Low | Sticky bottom bar appears when `selection.count > 0`. |
| Search with instant results | Spotify, Roon, and Doppler all filter in real-time as the user types. Users expect sub-100ms filtering. | Medium | Already debounced at 300ms from Phase 6; rendering must use LazyVStack for 38K-item perf. |
| Dark + Light theme auto-detect | macOS system preference for dark/light mode is universal. Apps that ignore it feel unpolished. | Low | DesignTokens already exist (Ayu palette). Map semantic tokens to `colorScheme`. |
| Keyboard shortcuts for core actions | Power users don't reach for the mouse for navigation (Cmd+1–4) or running updates (Cmd+Return). Music.app has 62 shortcuts. | Low | SwiftUI `.keyboardShortcut()` modifier. Map Cmd+1 Dashboard, Cmd+2 Browse, Cmd+3 Update, Cmd+4 Reports. |
| Hover states on all interactive elements | macOS cursor-based UX requires hover feedback. Without it the UI feels like a prototype. Verified across Spotify desktop, Linear, and Arc browser. | Low | `.onHover {}` modifier + background highlight. All list rows, buttons, and sidebar items. |
| Confident empty states | "No data" and "No Reports" are dead-ends that confuse users. Best practice (Toptal, UXPin, Mobbin): icon + specific message + primary CTA. | Low | Each view gets a tailored empty state with a call-to-action pointing to the correct next step. |
| Sidebar with clear active state | NavigationSplitView sidebar with selected item highlight is expected on macOS. Linear's 2024 redesign: "aligning labels, icons, and buttons vertically to reduce visual noise." | Low | Custom `listItemTint` or background overlay to override default blue. Verified: `customSelectionHighlight` requires workaround in SwiftUI. |
| Smooth view transitions | No jarring cuts between Dashboard, Browse, Update, Reports. Spotify uses content-area fade. | Low | SwiftUI `.contentTransition(.opacity)` or `matchedGeometryEffect`. |
| Correct information density | macOS apps are not iOS apps. Too sparse wastes screen; too dense is unreadable. Info density should be tuned like Doppler/Roon — dense but breathable. | Medium | Fixed row heights for track lists (44–48pt); metric cards with compact layout. No wasted space. |
| Progress feedback during batch operations | Batch running 38K tracks with no progress = frozen UI impression. UpdateCoordinator emits AsyncStream — this must surface per-track or per-batch progress. | Low | ProgressRing (already built in SharedUI) + per-item status badges in list view. |

---

## Differentiators

Features that set GenreUpdater apart from generic music apps and tag editors. Not universally expected, but add real value.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Half-circle gauge as Dashboard hero | Visual metaphor: library health as a fuel gauge. Instantly communicates metadata completeness without reading numbers. Unique to GenreUpdater in this domain. | High | Custom SwiftUI `Shape` + `Canvas`; three overlaid arcs for genre %, year %, consistency. GaugeKit (open source, Swift Package) available as reference. |
| Layered gauge overlays (genre / year / artist) | Toggle-able data layers on the gauge (like map overlays in Maps.app). Power users can drill into which dimension is incomplete. | High | Each overlay toggles a separate arc layer. Depends on cached metrics from GRDB/SwiftData. |
| Smart quick-actions reflecting library state | Instead of static "Update Genres" buttons, surface state-aware CTAs: "327 tracks missing genre — fix now." Makes the app feel intelligent and personalized. | Medium | Query GRDB for track counts by status; compose CTA label from real numbers at render time. |
| Duplicate artist detection visual indicator | GenreUpdater uniquely understands that "2CELLOS" vs "2Cellos" are duplicates. Surfacing this in Browse ("2 variants found") is a feature no other app provides. | High | ArtistMatcher (Phase 3A) already detects this. Browse can show a warning badge on artist rows with variants. Depends on LibrarySyncService pre-compute. |
| Confidence badge per proposed change | ChangePreviewPipeline produces confidence scores (Phase 5). Showing these per-track in Update view ("HIGH", "MEDIUM", "LOW") lets power users prioritize their review. ConfidenceBadge component already built. | Low | ConfidenceBadge (SharedUI) already exists. Wire up in Update preview list view. |
| Inline change preview before apply | Show the before/after diff inline in the track list before committing. Prevents surprises. Roon shows proposed changes before applying edits. | Medium | ChangePreviewPipeline already computes proposals. Render as two-line row: `was: Rock → now: Indie Rock`. |
| Smart filter builder | Compose filters like "genre = empty AND year < 1990 AND added this week." Power-user capability that no simple music player offers. Roon's Focus feature is the benchmark. | High | NSPredicate-based filter composition on cached SwiftData Track store. UI: chip-style tag builder. |
| Genre distribution horizontal bar chart | Visualize your library's genre breakdown sorted by count. Answers "what genres do I actually have?" Better than a raw list. | Medium | Swift Charts `BarMark` (horizontal). Already available in macOS 13+. |
| Year histogram / timeline | Shows decade concentration: "60% of library is 1990–2010." Answers "how old is my music?" | Medium | Swift Charts `BarMark` grouped by decade or 5-year buckets. |
| Section-level select-all (artist-level batch) | Selecting an entire artist's catalog (not just visible items) for batch processing. File managers (Finder) select visible items; this goes further by selecting the artist's entire MusicKit ID set. | Medium | Artist-level checkbox in Browse section header triggers selection of all tracks under that artist ID. Requires selection model keyed on `artistID` not just visible rows. |
| Undo affordance in change history | Change history in Reports with per-change undo. UndoCoordinator (Phase 5) already tracks this. Surfaces in Reports as a chronological log with undo button per entry. | Low | UndoCoordinator already built. Wire up ReportsChangeLog (SharedUI component already exists). |
| CSV export of change history | Power users want to audit what changed. CSVExporter (Phase 7 task). Differentiates from every music player that offers no audit trail. | Low | CSVExporter already in Phase 7 scope. Add Export button in Reports toolbar. |

---

## Anti-Features

Things to explicitly NOT build. Each one either violates the design philosophy, adds complexity without user value, or would be table stakes for a different product entirely.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Onboarding wizard / walkthrough | GenreUpdater's user is a power user who bought the app knowing what it does. Walkthroughs patronize them and slow the path to the library. | Use smart empty states on first launch that show the genuine value ("Import your 38K track library — it takes about 30 seconds"). |
| iOS/mobile-style tap targets (44pt min) | macOS cursor-based UI can use 28–36pt targets comfortably. iOS-sized targets waste screen space and make the density feel wrong. | Target 32–40pt row heights in lists, 28pt icon buttons in toolbars. |
| Full-library rescan on every launch | Re-reading 38K tracks from MusicKit on every cold start creates a 10–30 second wait. Makes the app feel slow even when the backend is fast. | LibrarySyncService delta scan: compare stored track count vs MusicKit count; only diff what changed. Show cached data immediately. |
| Per-track manual genre selector (dropdown) | This is a tag editor (like Mp3tag/Meta.app), not GenreUpdater's domain. GenreUpdater's value is in automated batch determination, not manual curation. | Offer "override" mode for individual tracks only, not as the primary UX. |
| Waveform visualization / playback controls | GenreUpdater doesn't play music. It reads/writes metadata via MusicKit + AppleScript. Adding playback would require AV Foundation entitlements and bloat scope. | Deep-link to Music.app for playback via `URL(string: "music://...")`. |
| Streaming service integration (Spotify API, etc.) | GenreUpdater works with locally-owned Apple Music library via MusicKit. Adding Spotify playlists or streaming metadata is a fundamentally different product. | Stay scoped to Apple Music / local library ownership. |
| Social features (share genre stats, etc.) | There is no community around metadata tagging. This would be dead weight. | Focus engineering on library health and batch reliability. |
| "What's New" dialogs / badges | These interrupt flow and annoy power users. Spotify's redesign complaints are partly attributed to this pattern. | Use a changelog in Settings accessed voluntarily. |
| Column browser (iTunes-style) | iTunes column browser (Genre → Artist → Album cascading columns) is powerful but takes enormous horizontal space and requires AppKit-style NSOutlineView or complex SwiftUI. Doppler chose a simpler list + drill-down instead. | Artist list → Album grid → Track list drill-down achieves the same result with SwiftUI-native navigation. |
| Global sidebar collapse (icon-only mode) | Spotify's icon-only collapsed sidebar generated significant user complaints. The nav items in GenreUpdater (4–5 items max) don't need collapsing — a narrow sidebar (200pt) is fine at all times. | Fixed sidebar width. Collapse is a feature for apps with 20+ nav items. |
| Onboarding permissions wall | Immediately asking for MusicKit authorization before showing anything feels hostile. | Show the Dashboard shell first, then trigger authorization when the user clicks "Sync Library" or similar voluntary CTA. |

---

## Feature Dependencies

```
LibrarySyncService delta scan
    → Dashboard instant data (cached metrics on launch)
    → Dashboard gauge (needs genre/year counts by track)
    → Smart quick-actions (needs per-status track counts)

MusicKit library load
    → Browse artist list (artists from MusicKit)
    → Browse drill-down (albums per artist)
    → Duplicate artist indicators (ArtistMatcher pre-compute)

SwiftData / GRDB cache
    → Dashboard instant data (metrics cached across launches)
    → Browse cached grouping (already done in Phase 6 - 38K perf)
    → Smart filter builder (filters against cached Track objects)

ChangePreviewPipeline (Phase 5)
    → Inline change preview
    → Confidence badge per track
    → Update view "proposed changes" list

UndoCoordinator (Phase 5)
    → Undo affordance in Reports
    → Change history chronological log

BatchProcessor + AsyncStream (Phase 5)
    → Real-time per-track progress
    → Persistent bulk-action bar (active during batch)

Custom selection model (shift-click, cmd-click)
    → Artist-level section select-all
    → Bulk-action bar

Smart filter builder
    → Update scope: "Smart Filter" mode (in addition to Selected Tracks / Full Library)
    → Browse filter panel (filter visible rows)

Genre/Year distribution (Swift Charts)
    → Reports view (charts)
    → Dashboard gauge overlays (genre layer)
```

---

## MVP Recommendation

### Phase 1: Dashboard + Skeleton (highest impact, blocks everything else)

1. Cached metrics load: hook LibrarySyncService into SwiftData/GRDB on launch, show cached data immediately
2. Half-circle gauge hero (custom SwiftUI Shape, single arc for genre %)
3. Metric cards around gauge (track count, genre coverage, year coverage, recently added)
4. Smart quick-actions with live counts
5. Skeleton shimmer while first sync runs (never show "0 tracks")

### Phase 2: Browse (most-used screen, currently broken)

1. Section headers with sticky alpha indexing
2. Artist → Album drill-down (SwiftUI NavigationStack push)
3. Shift-click + Cmd-click multi-select
4. Persistent bulk-action bar when selection > 0
5. Instant search (debounced 300ms, LazyVStack for performance)
6. Hover states on all rows

### Phase 3: Update + Reports (business value)

1. Inline change preview with confidence badges
2. Real-time batch progress per track
3. Genre distribution chart + year histogram in Reports
4. Change history with undo
5. Meaningful empty states across all views

### Defer for Post-Launch

- Smart filter builder (High complexity, Low launch urgency — power user feature)
- Duplicate artist visual indicators (requires pre-computation pass)
- Layered gauge overlays (adds complexity to gauge, implement after base gauge ships)
- CSV export (already in Phase 7 scope, low risk to defer)

---

## Sources

- [Spotify Community: New Your Library sidebar](https://community.spotify.com/t5/Your-Library/Desktop-New-Your-Library-sidebar/td-p/5571384) — MEDIUM confidence (community forum, not official docs)
- [Spotify Design: Reimagining Design Systems (Encore)](https://spotify.design/article/reimagining-design-systems-at-spotify) — HIGH confidence (official Spotify Design blog)
- [Doppler for Mac — MacStories Review](https://www.macstories.net/reviews/doppler-for-mac-offers-an-excellent-album-and-artist-focused-listening-experience-for-your-owned-music-collection/) — HIGH confidence (editorial review with UI detail)
- [Doppler Features — Brushed Type](https://brushedtype.co/doppler/features/) — HIGH confidence (official product page)
- [Linear 2024 UI Redesign](https://linear.app/now/how-we-redesigned-the-linear-ui) — HIGH confidence (official Linear engineering blog)
- [Linear LogRocket design analysis](https://blog.logrocket.com/ux-design/linear-design/) — MEDIUM confidence (third-party analysis)
- [Apple Music Column Browser — Apple Support](https://support.apple.com/guide/music/use-the-column-browser-muscde0b85e0/mac) — HIGH confidence (official Apple documentation)
- [Roon Focus Filter](https://roon.app/en/music/organization) — HIGH confidence (official Roon product page)
- [GaugeKit — SwiftUI gauge package](https://github.com/antonmartinsson/GaugeKit) — HIGH confidence (open source, verified active)
- [SwiftUI Gauge — AppCoda](https://www.appcoda.com/swiftui-gauge/) — HIGH confidence (well-regarded tutorial, verified against Apple docs)
- [Apple Developer: Creating a data visualization dashboard with Swift Charts](https://developer.apple.com/documentation/Charts/creating-a-data-visualization-dashboard-with-swift-charts) — HIGH confidence (official Apple documentation)
- [Bulk action UX guidelines — Eleken](https://www.eleken.co/blog-posts/bulk-actions-ux) — MEDIUM confidence (UX agency blog with examples)
- [Empty State UX Best Practices — Toptal](https://www.toptal.com/designers/ux/empty-state-ux-design) — MEDIUM confidence (professional UX design publication)
- [Skeleton Screens — Nestify](https://nestify.io/blog/skeleton-screens/) — MEDIUM confidence (single source)
- [SwiftUI List Performance on macOS — Apple Developer Forums](https://developer.apple.com/forums/thread/650238) — HIGH confidence (official Apple forums with Apple engineer responses)
- [Dark Mode Design Principles — Toptal](https://www.toptal.com/designers/ui/dark-ui-design) — MEDIUM confidence (professional publication)
- [NavigationSplitView sidebar customization — Apple Developer Forums](https://developer.apple.com/forums/thread/732856) — HIGH confidence (official Apple forums)
- [Sb SoundTag Mp3 PRO — App Store](https://apps.apple.com/us/app/soundtag-mp3-pro/id6756709593) — MEDIUM confidence (competitor pattern reference)
- [Meta Music Tag Editor — App Store](https://apps.apple.com/us/app/meta-music-tag-editor/id558317092?mt=12) — MEDIUM confidence (competitor pattern reference)
