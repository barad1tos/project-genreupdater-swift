# Architecture Patterns

**Domain:** macOS SwiftUI music app UI/UX redesign (GenreUpdater)
**Researched:** 2026-02-22
**Confidence:** HIGH (code inspection of existing codebase + verified web sources)

---

## Recommended Architecture

The redesign adds a UI layer on top of the existing backend without changing Services or Core. The architecture is an extension of what already works: App depends on Services depends on Core. All new work lives in App and SharedUI.

```
┌─────────────────────────────────────────────────────────────┐
│  App (SwiftUI)                                              │
│  ┌──────────────┐  ┌─────────────────────────────────────┐ │
│  │ Navigation   │  │ Screen Views                        │ │
│  │ MainView     │  │ DashboardView / BrowseView /        │ │
│  │ (NSplitView) │  │ UpdateView / ReportsView            │ │
│  └──────────────┘  └──────────────┬──────────────────────┘ │
│                                   │                         │
│  ┌────────────────────────────────▼──────────────────────┐ │
│  │ View Models (@Observable @MainActor)                  │ │
│  │ DashboardViewModel / BrowseViewModel / etc.           │ │
│  └────────────────────────────────┬──────────────────────┘ │
│                                   │ reads                   │
│  ┌────────────────────────────────▼──────────────────────┐ │
│  │ SharedUI Package                                      │ │
│  │ Theme Engine │ Components │ DesignTokens              │ │
│  └───────────────────────────────────────────────────────┘ │
└──────────────────────────────────┬──────────────────────────┘
                                   │ calls actors
┌──────────────────────────────────▼──────────────────────────┐
│  Services (actors: async/await)                             │
│  UpdateCoordinator / BatchProcessor / LibrarySyncService    │
│  MusicLibraryReader / APIOrchestrator / GRDBCacheService    │
└──────────────────────────────────┬──────────────────────────┘
                                   │ pure domain
┌──────────────────────────────────▼──────────────────────────┐
│  Core (no deps)                                             │
│  Track / GenreDeterminator / YearDeterminator / Matchers    │
└─────────────────────────────────────────────────────────────┘
```

**Package dependency rule (unchanged):** App → SharedUI → Core, App → Services → Core. SharedUI has no Services dependency. This constraint is load-bearing — it keeps the design system free of business logic.

---

## Component Boundaries

### 1. Theme Engine (SharedUI)

**Responsibility:** Centralize color, spacing, typography, shadow, and animation tokens. Provide theme switching without leaking NSWindow or AppKit concerns into views.

**What it owns:**
- `Ayu` palette (already exists — extend, do not replace)
- `Spacing`, `Radius`, `AppFont` tokens (already exist — extend)
- New `Shadow` token enum
- New `Animation` token enum (standard durations and curves)
- `AppTheme` enum: `.system`, `.dark`, `.light` — persisted via `@AppStorage`
- `ThemeEnvironmentKey` — a custom `@Entry` environment value injecting the resolved `ColorScheme`
- `ThemeModifier` — a `ViewModifier` that reads `@AppStorage("appTheme")` and calls `.preferredColorScheme()` on the root window scene

**What it does NOT own:**
- AppStorage keys live in SettingsView (writes) and GenreUpdaterApp (reads for `.preferredColorScheme`)
- `NSWindow.appearance` is set at the `WindowGroup` level via `.windowStyle` + `.preferredColorScheme`, not inside SharedUI

**Communicates with:** App (injected via `.environment`), Components (reads tokens directly via static enums — no injection needed for static tokens)

**Key insight:** `Ayu.bgPrimary` and friends already use `Color.adaptive(light:dark:)` which calls `NSColor` with an appearance closure. This means they already resolve correctly for both light and dark — no change needed. The theme engine's job is just to let the user override the system preference.

### 2. Design Tokens (SharedUI)

**What they are:** Static enum namespaces — `Spacing`, `Radius`, `AppFont`, `Ayu`. No classes, no injection, no dynamic dispatch.

**Evolution for redesign:**

Add `Shadow` tokens:
```swift
public enum Shadow {
    public static let card = ShadowStyle(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    public static let hover = ShadowStyle(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
    public static let float = ShadowStyle(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)
}
```

Add `Motion` tokens:
```swift
public enum Motion {
    public static let snappy = Animation.spring(duration: 0.25, bounce: 0.2)
    public static let smooth = Animation.easeInOut(duration: 0.2)
    public static let content = Animation.easeInOut(duration: 0.3)
    public static let entrance = Animation.spring(duration: 0.5, bounce: 0.3)
}
```

Add semantic aliases to `AppFont`:
```swift
public static let listHeader: Font = .system(size: 11, weight: .semibold)
public static let trackTitle: Font = .system(size: 13, weight: .medium)
public static let trackMeta: Font = .system(size: 11)
```

**Communicates with:** All App views (import SharedUI, use statically). No runtime coupling.

### 3. Component Library (SharedUI)

**What it owns:** Reusable, stateless/lightly-stateful SwiftUI views that know about design tokens but not about domain models.

**Existing components to keep and evolve:**
- `TrackRow` — used in BrowseView track list
- `TrackDetailView` — used in NavigationSplitView detail column
- `ConfidenceBadge` — used in UpdateView
- `ProgressRing` — used in batch progress
- `EmptyStateView` — replace ContentUnavailableView in redesign
- `TierBadge` / `PaywallOverlay` — monetization UI
- `ReportsChangeLog` / `ReportsCharts` — reports domain UI

**New components for redesign (added to SharedUI):**
- `HeroGauge` — half-circle arc (replaces full-circle `GaugeView` in App)
- `MetricRing` — single ring metric that wraps around the hero gauge
- `StatCard` — replaces `MetricCard` (denser, dark-styled)
- `ArtistListRow` — replaces `ArtistRow` (richer hover, count badge)
- `AlbumListRow` — replaces `AlbumCard`
- `FilterChip` — pill-shaped filter token for smart filters
- `ActionBanner` — already exists in some form per commit history
- `SectionIndexBar` — alphabet scroll index for Browse

**Rule:** Components receive plain Swift values (strings, numbers, enums). They do not take `Track` or `Core.*` types. Views in App translate domain models to view-friendly values before passing to components.

**Exception (acceptable):** `TrackRow` and `TrackDetailView` take `Core.Track` because they are tightly coupled to track display and the alternative (flattened structs) adds indirection without value. These stay as-is.

**Communicates with:** App views (used), SharedUI tokens (read), Core (TrackRow/TrackDetailView only).

### 4. Navigation Shell (App/Views/MainView)

**What it owns:** The `NavigationSplitView` skeleton, sidebar, column visibility state, track loading, and category routing.

**Current state:** Already implements the correct pattern. The `updateColumnVisibility()` logic toggleing between `.doubleColumn` and `.all` based on `selectedTrack` is correct.

**Changes needed for redesign:**

1. **Sidebar styling:** Replace default `.listStyle(.sidebar)` with a custom styled list to achieve the Spotify-dark look. On macOS, `listStyle(.sidebar)` gives the translucent sidebar background. For a fully custom dark sidebar, use a `VStack` inside a `.background(Ayu.bgSecondary)` instead, with custom `NavigationSplitViewColumnWidth`.

2. **Remove detail column for non-Browse screens:** The current `trackDetail` view shows "Select a Track" on Dashboard and Reports. The fix: make `columnVisibility` respond to `selectedCategory`, not just `selectedTrack`. Dashboard, Update, Reports → `.doubleColumn`. Browse with track → `.all`. Browse without track → `.doubleColumn`.

3. **Track store as source of truth:** Replace `@State private var tracks` with a subscription to `LibrarySyncService`. The view model pulls cached tracks on launch (instant) then receives delta updates via `AsyncStream`.

**Communicates with:** BrowseViewModel (selection binding), DashboardViewModel (via .task), AppDependencies (service access).

### 5. Dashboard Architecture (App/Views/DashboardView + DashboardViewModel)

**Problem with current design:** Metrics computed synchronously from parent-passed tracks array. No caching means "0 tracks" on first launch.

**Recommended pattern — cached metrics + delta:**

```swift
// DashboardViewModel.swift
@Observable @MainActor
final class DashboardViewModel {
    // Cached snapshot loaded instantly from SwiftData/UserDefaults
    private(set) var cachedMetrics: LibraryMetricsSnapshot?
    // Live metrics computed from tracks once loaded
    private(set) var liveMetrics: LibraryMetricsSnapshot?
    // What the gauge shows — cached until live is ready
    var displayedMetrics: LibraryMetricsSnapshot? { liveMetrics ?? cachedMetrics }

    private(set) var isRefreshing: Bool = false

    func loadCached(from store: SwiftDataTrackStore) async { ... }
    func refresh(tracks: [Track]) { ... } // updates liveMetrics + persists snapshot
}
```

The dashboard shows `cachedMetrics` immediately (no zero state), then animates to `liveMetrics` when the track load completes. The transition uses `withAnimation(Motion.content)` on the metric values.

**Half-circle gauge architecture:**

The `GaugeView` is currently a full circle. The hero element should be a half-circle (180° arc). The existing `Circle().trim(from:to:)` approach works — change rotation to `-180°` and trim to `0.5` maximum. The gauge supports toggle-able overlays: each overlay is an additional arc layer in the `ZStack`, shown/hidden via a `@State var visibleLayers: Set<GaugeLayer>`.

**Communicates with:** MainView (receives tracks array), AppDependencies (via Environment for SwiftDataTrackStore access to load cached metrics).

### 6. Browse Architecture (App/Views/BrowseView + BrowseViewModel)

**Problem:** All filtering and grouping is computed inline in view body properties. With 38K tracks, recomputation on every state change is visible.

**Recommended pattern — extract to @Observable ViewModel with async computation:**

```swift
@Observable @MainActor
final class BrowseViewModel {
    // Input
    var searchText: String = "" { didSet { scheduleSearch() } }
    var activeFilters: Set<BrowseFilter> = []

    // Output
    private(set) var sections: [LetterSection] = []
    private(set) var isSearching: Bool = false

    // Internal
    private var searchTask: Task<Void, Never>?
    private var allArtistSummaries: [ArtistSummary] = [] // cached, rebuilt on tracks change

    func loadTracks(_ tracks: [Track]) {
        // Rebuild allArtistSummaries once on track change
        // O(n) grouping — same as current code but done once
        Task.detached(priority: .userInitiated) { [weak self] in
            let summaries = Self.computeArtistSummaries(tracks)
            await MainActor.run { self?.allArtistSummaries = summaries }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.applyFilter()
        }
    }
}
```

**Key:** `allArtistSummaries` is computed once when `tracks` changes. The debounced search only filters the pre-computed summaries — O(n artists) not O(n tracks). For 38K tracks across ~2,271 artists, this is the dominant optimization.

**Multi-select state:**

SwiftUI's `List(selection: $selectedIDs)` with a `Set<String>` binding provides free shift-click and cmd-click on macOS — no custom gesture recognizers needed. This is built into `NSTableView` (which backs SwiftUI `List` on macOS). The `selection` binding type must be `Set<Track.ID>` (not `Set<Track>`). The view model holds `selectedTrackIDs: Set<Track.ID>` and computes `selectedTracks: [Track]` from it when needed.

**Communicates with:** MainView (selectedTrack binding for detail panel), BrowseViewModel (owned by BrowseView via `@State`).

### 7. Update Architecture (App/Views/UpdateView + UpdateWorkflowView)

**Current state:** Already well-architected. `WorkflowViewModel` drives phase transitions. The phase enum approach (`.configuring`, `.processing`, `.preview`, `.applying`, `.done`) is correct.

**Changes for redesign:** Visual-only. The architecture stays. The mode selector (Selected Tracks / Full Library / Smart Filter) becomes a richer UI segment. The progress view gets per-track status rows using `AsyncStream<ProgressUpdate>`.

**Communicates with:** WorkflowViewModel (owns `UpdateCoordinator`, `BatchProcessor`), MainView (via `.task { }` for track passing).

### 8. State Management for Selection

**For track-level selection (Browse drill-down):**
```swift
// In MainView — single source of truth for detail panel
@State private var selectedTrack: Track?
```
Passed as `@Binding` to BrowseView. When a track is selected, MainView responds by opening the detail column.

**For batch selection (Browse artist/album level):**
```swift
// In BrowseViewModel
var selectedArtistIDs: Set<String> = []
var selectedAlbumIDs: Set<String> = []
```
These feed the Update view when "Update Selected Artists" is triggered. The selection is passed as a filter to `UpdateCoordinator`.

**Native macOS multi-select works automatically** when `List(selection: $binding)` receives a `Set<ID>` binding. Shift-click extends the range; cmd-click toggles individual items. No custom gesture code needed. Source: [Multiple rows Selection in SwiftUI List | Sarunw](https://sarunw.com/posts/swiftui-list-multiple-selection/).

---

## Data Flow

### Launch Sequence
```
GenreUpdaterApp.task
  → AppDependencies.initialize()
      → ScriptInstaller.areScriptsInstalled()
      → MusicLibraryReader, AppleScriptBridge, SubscriptionService init
      → SwiftData + GRDB init
      → WorkflowServices init
  → appState = .ready → MainView appears
      → MainView.task → MusicLibraryReader.fetchAllTracks()
          → DashboardViewModel.loadCached() [instant, from SwiftData snapshot]
          → tracks array propagated to child views
          → DashboardViewModel.refresh(tracks:) [updates live metrics]
```

### Track Data Flow
```
MusicLibraryReader.fetchAllTracks() → [Core.Track]
  → MainView @State var tracks: [Track]  (single array, held at top level)
      → DashboardView(tracks:)   → DashboardViewModel.refresh()
      → BrowseView(tracks:)      → BrowseViewModel.loadTracks()
      → UpdateWorkflowView(tracks:)  (passed to coordinator on apply)
```

**Why tracks stay in MainView:** All three main views (Dashboard, Browse, Update) need the same track array. Lifting state to the parent avoids triple fetching. The track array is a value type slice — each view gets its own copy but points to the same COW buffer. No observable object needed; `@State var tracks: [Track]` in `MainView` is correct.

### Theme Data Flow
```
@AppStorage("appTheme") → AppTheme enum  (in GenreUpdaterApp or SettingsView)
  → .preferredColorScheme(appTheme.colorScheme)  on WindowGroup
      → SwiftUI propagates ColorScheme through environment
          → Ayu.bgPrimary, Ayu.fgSecondary, etc. resolve via NSColor appearance closure
```

No theme injection needed in individual views. `Ayu.*` colors already use `Color.adaptive(light:dark:)` which calls `NSColor(name:) { appearance in ... }`. The system's appearance propagation handles everything. **No custom `@Entry` theme key is needed for color resolution.** The `@Entry` pattern is only needed if adding theme-specific non-color tokens (e.g., a `spotifyDark` mode with different spacing).

### Search/Filter Data Flow
```
User types in .searchable text field
  → searchText @State updates (in BrowseView or BrowseViewModel)
  → 300ms debounce via Task.sleep + cancellation pattern
  → BrowseViewModel.applyFilter() runs on pre-computed allArtistSummaries
  → sections: [LetterSection] updates
  → List re-renders only changed sections (List diffing handles this)
```

The existing debounce pattern in `BrowseView` (`.task(id: searchText) { try? await Task.sleep(300ms) }`) is correct and should be moved into `BrowseViewModel` to keep view bodies thin.

### Update Progress Flow
```
WorkflowViewModel.startUpdate()
  → BatchProcessor.processTracks() → AsyncStream<ProgressUpdate>
      → WorkflowViewModel receives stream events on MainActor
      → Updates progress: Double, currentTrackName: String, completedCount: Int
          → UpdateView body re-renders only changed @Observable properties
```

The `@Observable` macro's property-level tracking means only views that read `progress` re-render when progress changes — not views reading `currentTrackName`. This is a key performance win over `ObservableObject`.

---

## Patterns to Follow

### Pattern 1: @Observable ViewModel Owned by View via @State

```swift
struct BrowseView: View {
    @State private var viewModel = BrowseViewModel()  // owned here
    let tracks: [Track]

    var body: some View {
        List(viewModel.sections) { ... }
            .task(id: tracks.count) {
                viewModel.loadTracks(tracks)
            }
    }
}
```

**Why:** `@State` gives the view ownership with SwiftUI's lifetime management. `@Observable` gives fine-grained property tracking. This is the current pattern in `DashboardView` and should be used consistently.

**When:** Every screen that needs non-trivial state management. Don't use for purely presentational views (components).

### Pattern 2: Async Computation with Task.detached for Heavy Work

```swift
// In BrowseViewModel
func loadTracks(_ tracks: [Track]) {
    Task.detached(priority: .userInitiated) { [tracks] in
        let summaries = Self.computeArtistSummaries(tracks)  // O(n) off main thread
        await MainActor.run { self.allArtistSummaries = summaries }
    }
}
```

**Why:** Computing artist summaries from 38K tracks involves grouping and sorting. Swift's `Dictionary(grouping:)` on 38K items is fast (~10ms) but still worth pushing off the main thread for responsiveness. The result is then applied on MainActor for safe UI updates.

**When:** Any computation that scales with library size (track grouping, metric aggregation, filter application on unfiltered data).

### Pattern 3: Debounce via Task Sleep + Cancellation

```swift
// In BrowseViewModel
private var searchTask: Task<Void, Never>?

var searchText: String = "" {
    didSet {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.applyFilter()
        }
    }
}
```

**Why:** When `searchText` changes rapidly (user typing), only the last value executes filter. This is the idiomatic Swift Concurrency debounce — no Combine needed. Already implemented correctly in `BrowseView` but inline in the view. Move to ViewModel.

**When:** Any user input that triggers expensive computation (search, filter changes).

### Pattern 4: Static Token Access, No Injection

```swift
// In any view or component
Text("Artist")
    .font(AppFont.trackTitle)
    .foregroundStyle(Ayu.fgPrimary)
    .padding(.horizontal, Spacing.md)
```

**Why:** Static enums are simpler, faster, and require no DI. SwiftUI already propagates `ColorScheme` via environment; `Ayu.*` colors read it internally via `NSColor` appearance closures. Adding a `@Environment(\.theme)` layer would add indirection without solving a real problem.

**When:** All color, spacing, typography, radius, and shadow tokens.

### Pattern 5: List with Native Multi-Select Binding

```swift
// Multi-select at artist level in BrowseView
@State private var selectedArtistIDs: Set<String> = []

List(viewModel.sections, selection: $selectedArtistIDs) { section in
    Section(section.letter) {
        ForEach(section.artists) { artist in
            ArtistListRow(artist: artist).tag(artist.id)
        }
    }
}
```

**Why:** SwiftUI's `List` on macOS backs onto `NSTableView`, which natively handles shift-click range extension and cmd-click toggle. No custom `NSViewRepresentable`, no custom gesture recognizer. This is free behavior.

**Constraint:** The `List` must use `.tag(item.id)` (not `.tag(item)`) when the selection binding is `Set<ID>`.

### Pattern 6: Matched Geometry for Sidebar Active Indicator

```swift
// In sidebar
@Namespace private var sidebarAnimation

ForEach(NavigationCategory.allInOrder) { category in
    ZStack {
        if selectedCategory == category {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.selection)
                .matchedGeometryEffect(id: "activeTab", in: sidebarAnimation)
        }
        Label(category.rawValue, systemImage: category.icon)
    }
    .onTapGesture { withAnimation(Motion.snappy) { selectedCategory = category } }
}
```

**Why:** `matchedGeometryEffect` makes the selection indicator slide between items smoothly instead of cross-fading. The `.@Namespace` lives in the sidebar view or `MainView`.

**When:** Any tab bar, segmented control, or selection indicator that should animate between positions. Not needed for regular content transitions.

### Pattern 7: Column Visibility Driven by Selection State

```swift
// In MainView
private func resolveColumnVisibility() -> NavigationSplitViewVisibility {
    switch selectedCategory {
    case .browse where selectedTrack != nil:
        return .all         // sidebar + content + detail
    case .browse:
        return .doubleColumn // sidebar + content, no "Select a Track" dead panel
    default:
        return .doubleColumn // Dashboard, Update, Reports: no detail column
    }
}
```

**Why:** The current code correctly toggles `.all` vs `.doubleColumn` but only checks `selectedTrack`. Dashboard and Reports also need to suppress the detail column. This pattern reads both `selectedCategory` and `selectedTrack` to make the decision.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Computing Filtered Lists in View Body

**What:** Property like `var filteredSections: [LetterSection]` declared as a computed `var` directly on the View struct.

**Why bad:** SwiftUI recomputes the view body for any state change. A 38K-track filter running synchronously on the main thread on every keystroke is a stutter source. The `BrowseView` currently does this.

**Instead:** Move to `BrowseViewModel.sections` backed by a debounced async computation. The view body reads `viewModel.sections` (already computed) — O(1) read.

### Anti-Pattern 2: Passing [Track] Down Multiple View Levels

**What:** DashboardView → GaugeSection → GaugeView all receive `tracks: [Track]` and each does some subset of the computation.

**Why bad:** Duplicates O(n) computation. Each child extracts slightly different subsets. Changes require touching multiple files.

**Instead:** Compute once in the ViewModel. Pass only the derived values (doubles, ints, arrays of named tuples). The view hierarchy receives `genreFillPercent: Double`, `totalTracks: Int`, not `tracks: [Track]`.

### Anti-Pattern 3: Using LazyVStack for the Main Track List

**What:** Replacing `List` with `ScrollView { LazyVStack { ForEach(38000 tracks) } }` for full styling control.

**Why bad:** `LazyVStack` does NOT recycle views. Once a row scrolls into view and back out, its view is retained in memory. For 38K tracks, this means catastrophic memory usage and eventual OOM. Apple's documentation confirms List uses NSTableView cell recycling; LazyVStack does not.

**Instead:** Use `List` for the track list (cell recycling), accept its styling constraints, and style rows heavily instead of the container. For section headers with alphabetical index, `List(sections)` with `Section(letter)` gives native sticky headers free.

**Exception:** `LazyVStack` is fine for Dashboard content (bounded number of cards, not 38K rows).

### Anti-Pattern 4: Separate Theme Object with @Environment Injection

**What:** Creating a `class Theme: Observable` injected via `.environment(theme)` that every view reads via `@Environment(Theme.self)`.

**Why bad (for this codebase):** `Ayu.*` colors already adapt to light/dark via `NSColor` appearance closures. The `ColorScheme` environment value from SwiftUI propagates automatically. Adding a separate injectable theme object doubles the indirection for no benefit. Every new component must accept `@Environment(Theme.self)` — boilerplate with no payoff.

**Instead:** `Ayu.*` static properties + `preferredColorScheme()` on the root scene. Only add injectable theme tokens if there is a genuine runtime variant that cannot be expressed with `Color.adaptive(light:dark:)`.

### Anti-Pattern 5: Using actor Instead of @Observable @MainActor for ViewModels

**What:** Making `BrowseViewModel` an `actor` to protect its mutable state.

**Why bad:** SwiftUI views can only access `actor`-isolated properties via async/await, which creates awkward calling patterns and prevents direct binding. Apple's guidance explicitly says: "Do not use an actor for your SwiftUI data models." `@Observable @MainActor` achieves thread safety for UI purposes because all access is on the main actor, while still allowing synchronous reading in view bodies.

**Instead:** `@Observable @MainActor final class ViewModel`. For CPU-heavy computation, use `Task.detached` and return results via `await MainActor.run { }`.

---

## Scalability Considerations

| Concern | At Current (38K tracks) | At 100K tracks | At 500K tracks |
|---------|------------------------|----------------|----------------|
| Track array in memory | ~15MB (fine) | ~40MB (fine) | ~200MB (caution) |
| Artist grouping | ~2K artists, fast | ~5K artists, ~5ms off-thread | ~25K artists, needs chunking |
| Browse List rendering | Cell recycling, only visible rows in memory | Same | Same |
| Dashboard metric aggregation | O(n) single pass, <5ms | <15ms | <80ms, move to background |
| Search filter | O(artists), ~1ms | ~3ms | ~15ms |
| SwiftData snapshot for cached metrics | Tiny (one row) | Same | Same |

The 300ms debounce on search and the `Task.detached` grouping computation provide sufficient headroom for the foreseeable library size. No paging or windowing is needed for the Browse drill-down because the artist list (~2,271 items) is well within `List`'s efficient rendering range.

---

## Build Order

Dependencies between components determine the safe implementation order. Always build what lower layers need before what uses them.

### Phase 1: Design System Foundation (SharedUI — no App dependencies)

**What:** Extend existing tokens; add Shadow, Motion enums; define new component shells.

**Why first:** Every subsequent component and view imports SharedUI. Building tokens first means component work never blocks on "what color is this?" Later phases can be built and previewed in isolation.

**Files:**
1. `SharedUI/Theme/DesignTokens.swift` — add `Shadow`, `Motion` enums
2. `SharedUI/Theme/AyuColors.swift` — verify existing, possibly add semantic aliases
3. `SharedUI/SharedUI.swift` — update public exports

**Does not depend on:** App, ViewModels, Services changes.

### Phase 2: Theme Switching (App — depends on Phase 1)

**What:** `AppTheme` enum + `@AppStorage` persistence + `.preferredColorScheme()` on `WindowGroup`.

**Why second:** Theme switching must work before any screen is redesigned, otherwise every visual review is done in the wrong color mode.

**Files:**
1. `App/GenreUpdaterApp.swift` — add `@AppStorage("appTheme")` + `.preferredColorScheme()` on WindowGroup
2. `App/Views/SettingsView.swift` — add theme picker

**Does not depend on:** New components, ViewModel changes.

### Phase 3: Shared Components (SharedUI — depends on Phase 1)

**What:** New and evolved components: `HeroGauge`, `StatCard`, `ArtistListRow`, `AlbumListRow`, `FilterChip`, `SectionIndexBar`, `ActionBanner`.

**Why third:** Screen views import these components. Having them working in isolation (via `#Preview`) before wiring into screens allows parallel visual work.

**Files:** One file per component in `SharedUI/Sources/SharedUI/`. Each can be previewed independently.

**Does not depend on:** ViewModel changes, MainView changes.

### Phase 4: Navigation Shell (App — depends on Phase 2)

**What:** Restyle sidebar, fix column visibility logic, add matched geometry for active indicator.

**Why fourth:** Once theme switching works and components exist, the shell can be restyled. Fixing column visibility now means subsequent screen work happens in the correct layout context.

**Files:**
1. `App/Views/MainView.swift` — sidebar styling, `resolveColumnVisibility()` fix, matched geometry

**Depends on:** Phase 1 (tokens), Phase 2 (theme).

### Phase 5: Dashboard Redesign (App — depends on Phases 1, 3, 4)

**What:** Half-circle hero gauge, metric ring, cached metrics via `SwiftDataTrackStore` snapshot, smart quick actions.

**Why fifth:** Dashboard is the first impression. It depends on `HeroGauge` (Phase 3) and the fixed navigation shell (Phase 4).

**Files:**
1. `App/ViewModels/DashboardViewModel.swift` — add `cachedMetrics`, `liveMetrics`, `loadCached()`
2. `App/Views/DashboardView.swift` — rearrange layout, use HeroGauge
3. `App/Views/Components/GaugeView.swift` — can be archived or converted to HeroGauge

**Depends on:** Phase 3 (HeroGauge component), Phase 4 (shell).

### Phase 6: Browse Redesign (App — depends on Phases 1, 3, 4)

**What:** Extract `BrowseViewModel`, async artist grouping, multi-select binding, filter chips, richer row styling.

**Why sixth:** Browse is independent of Dashboard. Both can be done in parallel after Phase 4 but Browse is more complex (ViewModel extraction, multi-select state).

**Files:**
1. `App/ViewModels/BrowseViewModel.swift` — new file; extract all computed data from BrowseView
2. `App/Views/BrowseView.swift` — consume ViewModel, add multi-select, use new row components

**Depends on:** Phase 3 (ArtistListRow, AlbumListRow, FilterChip), Phase 4 (shell).

### Phase 7: Update and Reports Polish (App — depends on Phases 1, 3)

**What:** Visual improvements to Update workflow and Reports — richer mode selector, better progress UI, non-empty Reports state.

**Why seventh:** These screens are functionally correct. Visual polish is lower priority than fixing the Dashboard and Browse UX problems.

**Files:**
1. `App/Views/UpdateWorkflowView.swift` — mode selector redesign, richer progress
2. `App/Views/ReportsView.swift` — improved empty state, layout polish
3. `SharedUI/Charts/ReportsCharts.swift` — visual refinements

**Depends on:** Phase 3 (components), existing workflow ViewModels (unchanged).

### Phase 8: Animations and Polish (App, SharedUI — depends on all prior phases)

**What:** Content transitions between navigation categories, entrance animations on Dashboard metrics, hover states, press states on interactive elements.

**Why last:** Animations require stable views to animate. Adding animations before views are finalized risks double work when layout changes.

**Files:** Spread across views — `.animation()`, `.transition()`, `.matchedGeometryEffect()` additions.

---

## Sources

- Existing codebase: inspected `MainView.swift`, `DashboardView.swift`, `BrowseView.swift`, `DashboardViewModel.swift`, `AppDependencies.swift`, `DesignTokens.swift`, `AyuColors.swift` — HIGH confidence (direct code inspection)
- [Multiple rows Selection in SwiftUI List | Sarunw](https://sarunw.com/posts/swiftui-list-multiple-selection/) — native shift/cmd-click on macOS — HIGH confidence
- [Enabling Selection in SwiftUI List on macOS | SerialCoder.dev](https://serialcoder.dev/text-tutorials/swiftui/enabling-selection-double-click-and-context-menus-in-swiftui-list-on-macos/) — macOS List multi-select behavior — HIGH confidence
- [List or LazyVStack | fatbobman.com](https://fatbobman.com/en/posts/list-or-lazyvstack/) — cell recycling behavior difference — HIGH confidence
- [Demystifying SwiftUI List Responsiveness | fatbobman.com](https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/) — large dataset best practices — HIGH confidence
- [SwiftUI Views and @MainActor | fatbobman.com](https://fatbobman.com/en/posts/swiftui-views-and-mainactor/) — @Observable @MainActor pattern — HIGH confidence
- [@Entry macro | SwiftLee](https://www.avanderlee.com/swiftui/entry-macro-custom-environment-values/) — custom environment values with @Entry — HIGH confidence (Xcode 16+, macOS 15+)
- [Reading and setting color scheme in SwiftUI | nilcoalescing.com](https://nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/) — preferredColorScheme + AppStorage pattern — HIGH confidence
- [Important: Do not use an actor for SwiftUI data models | HackingWithSwift](https://www.hackingwithswift.com/quick-start/concurrency/important-do-not-use-an-actor-for-your-swiftui-data-models) — actor vs @Observable @MainActor — HIGH confidence
- [matchedGeometryEffect | Design+Code](https://designcode.io/swiftui-handbook-matched-geometry-effect/) — matched geometry sidebar pattern — MEDIUM confidence
- [Applying Liquid Glass to custom views | Apple Developer](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) — glassEffect API — HIGH confidence (official docs, macOS 26+)
- [Yielding and debouncing in Swift Concurrency | Swift with Majid](https://swiftwithmajid.com/2025/02/18/yielding-and-debouncing-in-swift-concurrency/) — Task.sleep debounce pattern — HIGH confidence
