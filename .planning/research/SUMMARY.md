# Project Research Summary

**Project:** GenreUpdater — UI/UX Redesign Milestone
**Domain:** macOS SwiftUI music library management app (Spotify/Doppler-inspired redesign)
**Researched:** 2026-02-22
**Confidence:** HIGH

## Executive Summary

GenreUpdater's backend is complete through Phase 6. The redesign task is purely a UI layer built on top of existing Services and Core — no business logic changes. The recommended approach follows Doppler and Linear's design patterns: dense-but-breathable dark-first aesthetic, hierarchical Artist → Album → Track navigation, and instant data on launch via cached metrics. The existing Ayu color system, DesignTokens, SharedUI components, and ViewModels provide a strong foundation. The redesign extends what's there, not replaces it.

The single most important architectural decision — already validated — is using SwiftUI `List` (not `LazyVStack`) for the Browse artist/album lists. LazyVStack has no view recycling: at 2,271 artists it takes 52 seconds to scroll to the bottom and grows memory unboundedly. Everything else in the Browse redesign depends on this choice being made correctly from day one. The Dashboard redesign depends on a cached-metrics-first loading strategy: show SwiftData snapshot immediately, animate to live metrics once MusicKit finishes — never show "0 tracks."

The primary risks are performance (macOS 15 scroll regression, main-thread search filtering), correctness (theme override not piercing AppKit surfaces, `@Observable` ViewModels recreated without `@State`), and visual polish (Ayu light-mode contrast below WCAG AA, animation collisions during navigation). All risks have known mitigations documented in PITFALLS.md. Only one new dependency is needed: SwiftUI-Shimmer for skeleton loading states.

## Key Findings

### Recommended Stack

The stack is 95% already decided. The app targets macOS 15+, Swift 6 strict concurrency, SwiftUI with `@Observable`, and uses existing Swift Charts for all data visualization. The correct approach is to build the gauge as a custom `Circle().trim()` shape (following the existing ProgressRing pattern), not native `Gauge` view (no half-circle style exists) and not GaugeKit (watchOS-focused, 2021). Theme switching uses `preferredColorScheme` on the WindowGroup plus `NSApp.appearance` to cover AppKit surfaces — the Ayu color system needs no replacement.

**Core technologies:**
- SwiftUI `List` with `Section` — Browse artist/album/track hierarchy; AppKit-backed cell recycling
- `Circle().trim()` shapes — custom half-circle gauge; extends existing ProgressRing pattern
- Swift Charts (`BarMark`, `AreaMark`) — genre distribution, year histogram, sparklines; already in use
- `PhaseAnimator` + `.contentTransition(.numericText())` — loading sequences and counter animations
- `ContentUnavailableView` — empty states; macOS 14+, already used in MainView
- SwiftUI-Shimmer (markiv) — skeleton loading; only new dependency needed

**What to avoid:**
- GaugeKit, ColorTokensKit-Swift, DSFSparkline, Lottie, Rive, DSFToolbar, KeyboardShortcuts — all unnecessary given existing stack
- `LazyVStack` for any list longer than ~50 items — no view recycling, fatal for 38K track library

### Expected Features

**Must have (table stakes):**
- Instant data on launch — show cached SwiftData metrics immediately, never "0 tracks"
- Skeleton/shimmer loading states — distinguish "loading" from "empty"
- Artist → Album → Track drill-down hierarchy — 2,271 artists require this; flat list is unusable
- Sticky alphabetical section headers — standard for any macOS library with 2K+ items
- Shift-click + Cmd-click multi-select — SwiftUI `List(selection: $Set<ID>)` gives this for free
- Persistent bulk-action bar when selection count > 0 — must survive scrolling
- Real-time search with debounce — 300ms, computation off main thread
- Dark + Light theme with system auto-detect — `@AppStorage` + `preferredColorScheme` + `NSApp.appearance`
- Keyboard shortcuts Cmd+1–4 for navigation, Cmd+Return to start update
- Hover states on all interactive rows — macOS cursor-based UX requirement
- Per-screen empty states with CTA — each view's first impression when no data exists
- Progress feedback during batch operations — AsyncStream from BatchProcessor already emits this

**Should have (differentiators):**
- Half-circle gauge dashboard hero — visual library health metaphor; unique in domain
- Smart quick-actions with live counts ("327 tracks missing genre — fix now")
- Confidence badge per proposed change — ConfidenceBadge already in SharedUI
- Inline change preview (before/after diff) — ChangePreviewPipeline already computes this
- Genre distribution bar chart + year histogram — Swift Charts, already partially built
- Undo affordance in change history — UndoCoordinator already built
- matchedGeometryEffect sidebar active indicator — sliding highlight between nav items

**Defer for post-launch:**
- Smart filter builder (chip-style predicate composer) — high complexity, low launch urgency
- Layered gauge overlays (toggle-able arcs) — add after base gauge ships
- Duplicate artist visual indicators — needs pre-computation pass
- CSV export — already in Phase 7 scope, low risk to defer

**Anti-features (explicitly out):**
- Onboarding wizard, per-track manual genre selector, waveform/playback, streaming service integration, global sidebar collapse, "What's New" dialogs, iOS-sized touch targets

### Architecture Approach

All new work lives in the App target and SharedUI package. Services and Core are unchanged. The pattern is `@Observable @MainActor` ViewModels owned by views via `@State private var viewModel = MyViewModel()`. Heavy computation (artist grouping, search filtering) moves off the main thread via `Task.detached` with results applied via `await MainActor.run`. Static Ayu/Spacing/AppFont tokens need no injection — they resolve via NSColor appearance closures automatically. Theme switching requires both `preferredColorScheme` on WindowGroup (SwiftUI) and `NSApp.appearance` (AppKit surfaces).

**Major components:**
1. **Theme Engine extension** (SharedUI) — add `Shadow` and `Motion` token enums; `AppTheme` enum with `@AppStorage` persistence; no new injectable theme object needed
2. **HeroGauge** (SharedUI) — half-circle `Circle().trim()` with layered arcs; extends ProgressRing; built as a stateless component receiving `Double` values, not `[Track]`
3. **BrowseViewModel** (App) — new file; extracts all O(n) computation out of BrowseView body; pre-computes `allArtistSummaries` once on track load; debounced search filters pre-computed data only
4. **DashboardViewModel evolution** (App) — adds `cachedMetrics` (instant from SwiftData) and `liveMetrics` (computed after MusicKit load); `displayedMetrics` shows cached until live is ready
5. **MainView column visibility fix** — extend `resolveColumnVisibility()` to return `.doubleColumn` for Dashboard/Update/Reports; only `.all` for Browse with a selected track

**Build order (strict dependency chain):**
Phase 1 (design system tokens) → Phase 2 (theme switching) → Phase 3 (SharedUI components) → Phase 4 (navigation shell) → Phase 5 (Dashboard) → Phase 6 (Browse) → Phase 7 (Update + Reports polish) → Phase 8 (animations + final polish)

### Critical Pitfalls

1. **LazyVStack grows forever** — Use `List` with `Section` for artist/album lists. Never `LazyVStack` for Browse hierarchy. At 2,271 artists, LazyVStack takes 52s to scroll and grows memory unboundedly. `LazyVStack` is only acceptable for bounded dashboard cards.

2. **Search computation on main thread** — Even with 300ms debounce, the filter computation itself must run via `Task.detached`, not in a `.task(id:)` modifier (which inherits `@MainActor`). Pre-compute artist groupings once; search only filters the pre-computed ~2K-item array.

3. **`@Observable` ViewModel lifecycle** — Every ViewModel must be `@State private var viewModel = MyViewModel()`. Without `@State`, SwiftUI recreates the object on every parent re-render, causing repeated expensive computations and multiple observer registrations.

4. **`preferredColorScheme` doesn't cover all surfaces** — Add `NSApp.appearance` alongside the SwiftUI modifier. Sheets, `DatePicker`, and new windows ignore `preferredColorScheme` on macOS. The NSColor dynamic provider in AyuColors.swift may also need a `themeVersion` counter to force SwiftUI invalidation after `NSApp.appearance` changes.

5. **macOS 15 scroll hit-test regression** — Apply `.contentShape(.rect)` on all scrollable row views proactively. The `_hitTestForEvent` regression (85% CPU during trackpad scroll) affects all SwiftUI scroll containers on macOS 15. No workaround fully fixes it, but eliminating complex hit-test shapes in rows reduces severity.

## Implications for Roadmap

Based on research, the architecture's dependency graph drives a clear 8-phase build order. Each phase unblocks the next.

### Phase 1: Design System Foundation
**Rationale:** Every subsequent component reads design tokens. Building tokens first means no downstream phase ever blocks on "what color/shadow/animation is this?" SharedUI has zero App dependencies — this phase can be done in pure isolation.
**Delivers:** `Shadow` enum, `Motion` enum, semantic `AppFont` aliases added to DesignTokens; Ayu light-mode contrast fixed to WCAG AA; minimum window width set (900pt).
**Avoids:** Pitfalls 14 (hardcoded colors), 15 (toolbar overflow), 17 (light-mode contrast).

### Phase 2: Theme Switching
**Rationale:** Must work before any screen is visually reviewed in the wrong color mode. Touching GenreUpdaterApp.swift once for `@AppStorage` + `preferredColorScheme` + `NSApp.appearance` avoids later rework.
**Delivers:** `AppTheme` enum, `@AppStorage` persistence, `NSApp.appearance` sync, theme picker in SettingsView.
**Avoids:** Pitfalls 4 (preferredColorScheme incomplete), 11 (NSColor not invalidating on override).

### Phase 3: SharedUI Component Library
**Rationale:** Screen views import these components. Building components before screens means screen work never blocks on "I need this row component." Each component is independently previewable via `#Preview`.
**Delivers:** `HeroGauge`, `StatCard`, `ArtistListRow`, `AlbumListRow`, `FilterChip`, `SectionIndexBar`, `ActionBanner` (new/evolved components); shimmer dependency added to SharedUI Package.swift.
**Avoids:** Pitfall 9 (Canvas no hit testing — build gauge as Shape, not Canvas).

### Phase 4: Navigation Shell
**Rationale:** Column visibility fix must be in place before screen work begins. Without it, Dashboard and Reports are cramped by the spurious detail column.
**Delivers:** Sidebar restyled (Ayu dark background, matchedGeometryEffect active indicator), `resolveColumnVisibility()` extended to category-aware logic.
**Avoids:** Pitfall 5 (detail column wastes space on non-Browse screens).

### Phase 5: Dashboard Redesign
**Rationale:** Dashboard is the first impression and the highest-impact screen. Depends on HeroGauge (Phase 3) and the fixed shell (Phase 4).
**Delivers:** Half-circle HeroGauge hero, MetricRing, StatCards, cached-first metrics loading (SwiftData snapshot → live), smart quick-actions with live counts, skeleton shimmer on first launch.
**Avoids:** Pitfalls 3 (ViewModel lifecycle), 16 (animation collision with navigation), 18 (task ID instability).

### Phase 6: Browse Redesign
**Rationale:** Most-used screen, currently most broken. Independent of Dashboard — can be parallelized after Phase 4 but higher complexity warrants sequential approach.
**Delivers:** New `BrowseViewModel` (async artist grouping, debounced search off main thread), `List(selection: $Set<ID>)` multi-select (shift/cmd-click free), persistent bulk-action bar, richer row styling via new components.
**Avoids:** Pitfalls 1 (LazyVStack), 6 (main-thread search), 7 (row highlight conflict), 8 (ForEach ID instability), 12 (multi-select only works in List).

### Phase 7: Update and Reports Polish
**Rationale:** Both screens are functionally correct. Visual polish is lower priority than fixing Browse and Dashboard UX problems. Architecture stays unchanged.
**Delivers:** Richer mode selector UI, per-track progress rows from AsyncStream, improved Reports empty state, chart visual refinements.

### Phase 8: Animations and Final Polish
**Rationale:** Animations require stable, finalized views. Adding animations before layout is locked risks double work.
**Delivers:** Content transitions between categories, entrance animations on Dashboard metrics, hover states across all rows, press states on interactive elements, accessibility audit.
**Avoids:** Pitfall 16 (defer gauge entrance animation 50ms after navigation cross-fade).

### Phase Ordering Rationale

- Tokens before components before screens: downstream work never blocks on primitives
- Theme switching in Phase 2 (not later) so every screen review happens in the correct color mode
- Dashboard before Browse despite Browse being more-used: Dashboard has more architectural dependencies (cached metrics, gauge component) and is the app's first impression for App Store reviewers
- Animations last: stable layout is a prerequisite; applying motion to moving targets wastes time

### Research Flags

Phases with standard well-documented patterns (skip deep research):
- **Phase 1 (Design tokens):** Extending existing enums — no research needed
- **Phase 2 (Theme switching):** Pattern fully documented in PITFALLS.md + STACK.md
- **Phase 4 (Navigation shell):** matchedGeometryEffect pattern documented in ARCHITECTURE.md
- **Phase 7 (Update/Reports):** Architecture unchanged; visual-only work

Phases that may need targeted investigation during planning:
- **Phase 3 (HeroGauge):** Interactive tap targets on arc segments require verification — transparent `Circle().trim()` tap target pattern should be prototyped early
- **Phase 6 (Browse):** `Table` view as alternative to `List` for track-level display (column headers for title/artist/album/year/genre) — worth a spike before committing to `List` rows

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All technology choices verified against Apple docs and existing codebase. One new dep (Shimmer) is minimal risk. |
| Features | HIGH | Patterns from Doppler, Roon, Linear, Music.app cross-validated. Anti-features list is well-reasoned. |
| Architecture | HIGH | Build order derived from actual dependency graph, not opinion. Multi-select behavior verified against Sarunw + SerialCoder sources. |
| Pitfalls | HIGH | Most pitfalls confirmed via Apple Developer Forums with Apple engineer responses or WWDC documentation. macOS 15 scroll regression is a live bug. |

**Overall confidence:** HIGH

### Gaps to Address

- **Ayu light-mode contrast values:** Need exact recalculation — current fgPrimary (0x5C6166) on white is ~4.2:1, just below WCAG AA. Fix values before Phase 1 ships.
- **SwiftUI-Shimmer version:** Verify current release version at https://github.com/markiv/SwiftUI-Shimmer/releases before adding to Package.swift (research used "from: 1.5.0" as placeholder).
- **`Table` vs `List` for track-level Browse:** The research recommends `List` but `Table` (macOS 12+) natively renders columns and supports `Set`-based multi-select — worth a prototype spike before committing to the Browse row design.
- **macOS 15 scroll regression timeline:** Apple marked this "Potential fix identified." Monitor 15.3+ release notes; the mitigation (`.contentShape(.rect)`) reduces but doesn't eliminate the issue.

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation — SwiftUI List, NavigationSplitView, ContentUnavailableView, PhaseAnimator, glassEffect, Swift Charts
- [List or LazyVStack — Fatbobman](https://fatbobman.com/en/posts/list-or-lazyvstack/) — cell recycling benchmarks
- [Demystifying SwiftUI List Responsiveness — Fatbobman](https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/) — 38K track performance
- [Multiple rows Selection in SwiftUI List — Sarunw](https://sarunw.com/posts/swiftui-list-multiple-selection/) — native shift/cmd-click
- [Enabling Selection on macOS — SerialCoder.dev](https://serialcoder.dev/text-tutorials/swiftui/enabling-selection-double-click-and-context-menus-in-swiftui-list-on-macos/)
- [Reading and setting color scheme — NilCoalescing](https://nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/) — preferredColorScheme pattern
- [SwiftUI ScrollView performance in macOS 15 — Apple Developer Forums](https://developer.apple.com/forums/thread/764264) — hitTestForEvent regression
- [Do not use an actor for SwiftUI data models — HackingWithSwift](https://www.hackingwithswift.com/quick-start/concurrency/important-do-not-use-an-actor-for-your-swiftui-data-models)
- [SwiftUI Tasks Blocking the MainActor — Use Your Loaf](https://useyourloaf.com/blog/swiftui-tasks-blocking-the-mainactor/)
- Existing codebase: direct inspection of MainView, DashboardView, BrowseView, DesignTokens, AyuColors

### Secondary (MEDIUM confidence)
- [Doppler for Mac — MacStories Review](https://www.macstories.net/reviews/doppler-for-mac-offers-an-excellent-album-and-artist-focused-listening-experience-for-your-owned-music-collection/) — feature pattern reference
- [Linear 2024 UI Redesign](https://linear.app/now/how-we-redesigned-the-linear-ui) — density and sidebar design patterns
- [Bulk action UX — Eleken](https://www.eleken.co/blog-posts/bulk-actions-ux) — persistent bulk-action bar UX guidance
- [SwiftUI List performance — medium.com/@chandra.welim](https://medium.com/@chandra.welim/swiftui-list-performance-smooth-scrolling-for-10-000-items-c64116dc276f) — 10K item benchmark (5.53s List vs 52.3s LazyVStack)
- [SwiftUI-Shimmer library](https://github.com/markiv/SwiftUI-Shimmer) — skeleton loading

---
*Research completed: 2026-02-22*
*Ready for roadmap: yes*
