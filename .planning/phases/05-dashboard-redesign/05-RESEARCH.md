# Phase 5: Dashboard Redesign - Research

**Researched:** 2026-02-23
**Domain:** SwiftUI Dashboard layout, cached-first data loading, SwiftData metrics persistence, HeroGauge redesign
**Confidence:** HIGH

## Summary

Phase 5 replaces the prototype DashboardView (GaugeView + MetricCard + top genres + QuickActionButton) with a redesigned version centered on the existing HeroGauge component from SharedUI, cached-first metrics, shimmer loading states, and soft quick actions. The existing codebase already has most building blocks: HeroGauge with concentric arcs and hover detection, ShimmerPlaceholder with `.gauge` and `.card` shapes, StatCard with elevation hover, and SwiftDataTrackStore for persistence. The primary new work is: (1) a SwiftData-backed metrics snapshot model for cached-first loading, (2) rewiring DashboardView to use HeroGauge instead of GaugeView, (3) adding trend indicators to metric cards, (4) redesigning quick actions to be soft/informational, and (5) handling all loading/empty states.

The HeroGauge needs modifications per CONTEXT.md: arc colors must change (Genre=Ayu.purple, Year=Ayu.info, Consistency=Ayu.accent), arcs should use stacked close-radius layout with subtle shadow between layers instead of the current concentric ring layout, and click behavior needs to navigate to relevant screens. The existing DashboardViewModel computes all needed metrics synchronously from in-memory tracks -- it needs extension to support cached snapshot loading and trend calculation.

**Primary recommendation:** Extend the existing DashboardViewModel with a two-phase loading pattern (cached snapshot first, then live MusicKit data), add a PersistedMetricsSnapshot SwiftData model, modify HeroGauge colors and arc layout, and replace GaugeView/MetricCard/QuickActionButton with the redesigned versions.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Center content: large track count number ("38,247") with "tracks" label underneath -- focus on library size
- Legend: compact inline legend always visible below gauge (colored dots + labels: Genre 85%, Year 72%, Consistency 90%), plus hover on any arc reveals extended details (e.g. "Genre: 1,234 of 1,450 tagged")
- Size: dominant, approximately 40% of content width (~280-320pt) -- the first thing visible on the Dashboard
- Arc layout: stacked segments on very close radii with subtle shadow between layers (layered depth effect, not concentric rings) -- feels like physical layers with slight z-separation
- Arc colors: Ayu semantic palette -- Genre = Ayu.purple, Year = Ayu.info, Consistency = Ayu.accent (consistent with existing app color usage)
- Consistency metric: percentage of tracks where BOTH genre AND year are filled -- fully processed tracks
- Click behavior: clicking on an arc navigates to the relevant screen (genre/year arcs -> Update)
- Animation: static fill values in Phase 5, draw-in animation deferred to Phase 8
- Top Genres section: REMOVED from Dashboard, moved to Reports screen
- Card set: 3 cards (NOT 4) -- Need Genre, Need Year, Recently Added. Track count already in gauge center, no duplication
- Layout: single row of 3 cards below the gauge
- Style: minimal with trend indicator -- arrow only visible by default, hover reveals delta number (e.g. "+12 since last scan")
- Trend baseline: compared to previous scan -- requires persisting a metrics snapshot in SwiftData
- Clickable: all cards navigate (Need Genre -> Update, Need Year -> Update, Recently Added -> Browse with "Recently Added" filter)
- Hover/press: combined elevation (shadow + subtle scale) + accent border glow -- must be CONSISTENT with press/hover patterns across the entire app (same timing, same easing, same feel as list rows and other interactive elements)
- Philosophy: soft shortcuts, not urgency-driven CTAs. Dashboard shows library STATE, does not pressure
- Tone: neutral labels with context (e.g. "Genre . 327 untagged") -- informative, not "Fix Now!"
- Live counts: derived from actual library state, update after background scan completes
- Zero-count actions: always show all actions even when count is 0 (display checkmark for completed states, e.g. "All genres tagged")
- First launch (no cache): full shimmer on ALL Dashboard elements -- gauge, metric cards, quick actions. Shape-matching shimmer (half-circle for gauge, rectangles for cards)
- Long load (>3 seconds): add progress text below gauge ("Loading library... 12,340 / 38,247") -- only appears after 3s threshold
- Cache-to-live transition: subtle "Updating..." indicator at top, numbers animate smoothly from cached to live values
- Data refresh: auto-scan on app launch, cached data as immediate fallback, quiet footer timestamp ("Updated 2 min ago")
- Empty library (0 tracks): friendly illustration/icon + soft message with a shortcut button to open Music.app
- MusicKit permission denied: clear permission prompt + "Open Settings" button to grant access
- Adaptive layout: cards reflow responsively on window resize (3 in row -> 2+1 -> stacked)

### Claude's Discretion
- Quick actions visual format and exact component design (soft, unobtrusive, complementary)
- Whether a title ("Library Health") appears above the gauge
- Exact spacing and typography between sections
- Shimmer timing and animation parameters
- Error state handling for failed scans
- Footer timestamp exact position and style

### Deferred Ideas (OUT OF SCOPE)
- Customizable Dashboard layout -- let users rearrange/hide Dashboard sections (future milestone)
- Draw-in animation for gauge arcs -- Phase 8
- Top Genres chart -- moved to Reports (Phase 7)
- Numeric text content transitions for cached -> live values -- Phase 8
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DASH-01 | Dashboard displays a half-circle gauge as the hero element showing library track count with genre/year/consistency arc layers | Existing HeroGauge in SharedUI needs color changes (Genre=Ayu.purple, Year=Ayu.info, Consistency=Ayu.accent) and arc layout adjustment (stacked close-radius with shadow). Click-to-navigate requires adding an `onArcTapped` callback. |
| DASH-02 | Dashboard shows cached metrics instantly on launch from SwiftData snapshot, then updates to live metrics via background delta-scan -- never displays "0 tracks" | New PersistedMetricsSnapshot SwiftData model stores last-known metrics. DashboardViewModel loads snapshot first, then refreshes from MusicKit. Two-phase loading pattern. |
| DASH-03 | First launch uses skeleton/shimmer animations (SwiftUI-Shimmer) to indicate loading instead of empty values | ShimmerPlaceholder already exists with `.gauge` and `.card` shapes. DashboardView switches between shimmer and real content based on ViewModel loading state. |
| DASH-04 | Quick action buttons reflect actual library state with live counts (e.g. "327 tracks missing genre -- fix now") | Redesign QuickActionButton to use neutral tone per CONTEXT.md. ViewModel already computes tracksNeedingGenre/tracksNeedingYear. Add zero-state checkmark display. |
</phase_requirements>

## Standard Stack

### Core (all existing -- no new dependencies)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI | macOS 14+ | View layer | Already used throughout app |
| SwiftData | macOS 14+ | Metrics snapshot persistence | Already used for PersistedTrack/ChangeLogEntry |
| MusicKit | macOS 14+ | Library data source | Already used via MusicLibraryReader |
| SwiftUI-Shimmer | 1.5.1 | Skeleton loading animations | Already in SharedUI Package.swift |
| @Observable | macOS 14+ | ViewModel state management | Already the project pattern per CLAUDE.md |

### Supporting (existing)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| OSLog | Apple | Logging | All service-level operations |
| LucideIcons | 0.575.0 | Navigation icons | Quick action icons if needed |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SwiftData for metrics snapshot | UserDefaults/AppStorage | SwiftData is already set up with ModelContainer; UserDefaults would require manual Codable encoding and wouldn't integrate with the existing persistence layer |
| LazyVGrid for card reflow | Manual GeometryReader breakpoints | LazyVGrid with `.adaptive` handles reflow automatically; GeometryReader requires manual breakpoint logic |

**Installation:**
No new dependencies required. All libraries are already in the project.

## Architecture Patterns

### Recommended Changes to Existing Structure
```
App/
├── ViewModels/
│   └── DashboardViewModel.swift    # MODIFY: add cached snapshot loading, trends
├── Views/
│   ├── DashboardView.swift         # REWRITE: use HeroGauge, new layout, loading states
│   └── Components/
│       ├── GaugeView.swift         # DELETE: replaced by SharedUI HeroGauge
│       ├── MetricCard.swift        # MODIFY: add trend hover, click navigation
│       └── QuickActionButton.swift # REWRITE: soft tone, zero-state, live counts
Packages/
├── SharedUI/Sources/SharedUI/
│   └── Components/
│       └── HeroGauge.swift         # MODIFY: arc colors, stacked layout, click callback, shadow layers
├── Services/Sources/Services/
│   └── Persistence/SwiftData/
│       ├── PersistedMetricsSnapshot.swift  # NEW: metrics cache model
│       └── ModelContainerFactory.swift     # MODIFY: add PersistedMetricsSnapshot to schema
```

### Pattern 1: Two-Phase Cached-First Loading
**What:** ViewModel loads persisted metrics snapshot instantly on init, then kicks off async MusicKit fetch to update with live data.
**When to use:** Dashboard launch -- user sees cached data immediately, never "0 tracks".
**Example:**
```swift
// DashboardViewModel.swift
@Observable @MainActor
final class DashboardViewModel {
    private(set) var loadingState: DashboardLoadingState = .loading
    private(set) var metrics: DashboardMetrics = .empty
    private(set) var previousMetrics: DashboardMetrics? // For trend calculation

    // Phase 1: Load cached snapshot (synchronous, from SwiftData)
    func loadCachedMetrics(from snapshot: PersistedMetricsSnapshot?) {
        guard let snapshot else {
            loadingState = .shimmer // First launch
            return
        }
        metrics = DashboardMetrics(from: snapshot)
        previousMetrics = metrics
        loadingState = .cached(lastUpdated: snapshot.timestamp)
    }

    // Phase 2: Refresh from live MusicKit data
    func refreshFromLive(tracks: [Track]) {
        let newMetrics = DashboardMetrics(from: tracks)
        previousMetrics = metrics.totalTracks > 0 ? metrics : nil
        metrics = newMetrics
        loadingState = .live
    }
}
```

### Pattern 2: Loading State Enum
**What:** Explicit enum modeling all possible Dashboard states to prevent invalid UI configurations.
**When to use:** DashboardView switches rendering based on state.
**Example:**
```swift
enum DashboardLoadingState: Equatable {
    case shimmer                          // First launch, no cache
    case cached(lastUpdated: Date)        // Showing cached data, live scan pending
    case updating                         // Live scan in progress
    case live                             // Showing live data
    case error(String)                    // Scan failed
    case permissionDenied                 // MusicKit access denied
    case emptyLibrary                     // 0 tracks in Music.app
}
```

### Pattern 3: Metrics Snapshot Persistence
**What:** A SwiftData `@Model` that stores aggregate dashboard metrics (not individual tracks), persisted after each successful scan.
**When to use:** On every successful library scan completion, save a snapshot for next launch.
**Example:**
```swift
@Model
public final class PersistedMetricsSnapshot {
    public var totalTracks: Int
    public var tracksWithGenre: Int
    public var tracksWithYear: Int
    public var tracksWithBoth: Int  // consistency
    public var tracksNeedingGenre: Int
    public var tracksNeedingYear: Int
    public var recentlyAdded: Int
    public var timestamp: Date

    // Computed percentages
    public var genreCoverage: Double { /* ... */ }
    public var yearCoverage: Double { /* ... */ }
    public var consistencyCoverage: Double { /* ... */ }
}
```

### Pattern 4: Adaptive Card Grid with LazyVGrid
**What:** Use `LazyVGrid` with `.adaptive(minimum:)` for responsive card reflow on window resize.
**When to use:** Metric cards section that must reflow 3 -> 2+1 -> stacked.
**Example:**
```swift
LazyVGrid(
    columns: [GridItem(.adaptive(minimum: 180, maximum: 280))],
    spacing: Spacing.md
) {
    ForEach(metricCards) { card in
        MetricCard(/* ... */)
    }
}
```

### Anti-Patterns to Avoid
- **Computing metrics in the View body:** Dashboard metrics are O(n) over 38K+ tracks. Never compute in body -- always precompute in ViewModel.
- **Using .task without id:** When tracks change, `.task(id: tracks.count)` ensures recomputation. Without `id`, the task only runs once.
- **Storing individual tracks in the snapshot:** The metrics snapshot stores ONLY aggregate numbers. Storing 38K tracks in a separate SwiftData model would duplicate PersistedTrack.
- **Animating arc draw-in during Phase 5:** Per CONTEXT.md, draw-in animation is deferred to Phase 8. Phase 5 uses static fill values (set progress directly, no animation on appear).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Shimmer loading animation | Custom gradient animation | SwiftUI-Shimmer `.shimmering()` | Already in SharedUI, handles timing/gradient direction |
| Skeleton shape matching | Manual path drawing | ShimmerPlaceholder with `.gauge`/`.card`/`.rectangle` | Already built with gauge arc shape and card shape |
| Adaptive grid reflow | Manual GeometryReader breakpoints | `LazyVGrid(.adaptive(minimum:))` | Handles reflow automatically as window resizes |
| Shadow elevation tokens | Raw `.shadow()` calls | `Shadow.subtle`/`.elevated` + `.ayuShadow()` | Design token system already exists |
| Motion/animation curves | Raw `.animation(.easeInOut)` | `Motion.curveFast`/`.curveDefault` | Consistency with rest of app guaranteed |
| Hover/press interaction | Custom gesture recognizers | Existing pattern: `.onHover` + `DragGesture(minimumDistance: 0)` + `.scaleEffect(0.98)` | StatCard/list rows already use this exact pattern |
| Relative timestamp | Manual date arithmetic | `RelativeDateTimeFormatter` | Apple's built-in handles "2 min ago", "1 hr ago" etc. |

**Key insight:** The SharedUI component library (Phase 3) already built most primitives. Phase 5 is primarily about wiring them together with a data flow layer (cached metrics) and layout adjustments, not building new components from scratch.

## Common Pitfalls

### Pitfall 1: ModelContainer Schema Must Include New Models
**What goes wrong:** Adding PersistedMetricsSnapshot without updating ModelContainerFactory causes a runtime crash -- SwiftData silently ignores unregistered models on fetch, then crashes on insert.
**Why it happens:** ModelContainerFactory.create() explicitly lists all model types in Schema(). A new @Model not added there won't be recognized.
**How to avoid:** Update `ModelContainerFactory.create()` to include `PersistedMetricsSnapshot.self` in the Schema array alongside `PersistedTrack.self` and `PersistedChangeLogEntry.self`.
**Warning signs:** "Cannot find model type" or silent fetch returning nil.

### Pitfall 2: HeroGauge Arc Color Changes Break Existing Tests
**What goes wrong:** HeroGauge currently uses `Ayu.accent` for Genre, `Ayu.success` for Year, `Ayu.info` for Consistency. CONTEXT.md requires Genre=Ayu.purple, Year=Ayu.info, Consistency=Ayu.accent. This is a breaking visual change.
**Why it happens:** GaugeLayer enum in HeroGauge.swift has hardcoded color assignments.
**How to avoid:** Update the GaugeLayer.color computed property. Since HeroGauge is in SharedUI (public), ensure any existing consumers are checked (currently only DashboardView via GaugeView wrapper, which is being replaced anyway).
**Warning signs:** Visual regression in previews.

### Pitfall 3: SwiftData Migration When Adding New Model
**What goes wrong:** Adding PersistedMetricsSnapshot to an existing schema could require a lightweight migration. If the model is added as a new table (not modifying existing models), SwiftData handles this automatically.
**Why it happens:** SwiftData performs automatic lightweight migration for additive schema changes (new models, new optional properties).
**How to avoid:** Since this is a NEW model (not modifying existing ones), SwiftData handles it automatically. No explicit migration plan needed. However, verify by testing on a device with existing data.
**Warning signs:** ModelContainer creation failure on launch.

### Pitfall 4: @State private var viewModel Pattern
**What goes wrong:** Using `@State private var viewModel = DashboardViewModel()` without `@State` causes SwiftUI to recreate the ViewModel on every parent re-render.
**Why it happens:** Per project decision (STATE.md): "@Observable ViewModels must be @State private var -- without @State SwiftUI recreates on every parent re-render".
**How to avoid:** Always use `@State private var viewModel = DashboardViewModel()` in DashboardView.
**Warning signs:** Metrics resetting to zero momentarily during navigation, flickering gauge.

### Pitfall 5: HeroGauge Line Cap Must Be .butt
**What goes wrong:** Per CLAUDE.md pitfall: "HeroGauge butt caps: Line cap must be .butt (not .round) for technical/minimalist look -- .round is only for ProgressRing".
**Why it happens:** When modifying HeroGauge arc layout, it's tempting to switch to .round for aesthetics.
**How to avoid:** Keep `lineCap: .butt` in all ArcShape strokes.
**Warning signs:** Visual inconsistency with design intent.

### Pitfall 6: Removing Draw-In Animation Prematurely
**What goes wrong:** CONTEXT.md says "static fill values in Phase 5, draw-in animation deferred to Phase 8". But HeroGauge currently HAS animation (animateDrawIn method with spring).
**Why it happens:** The existing animation is from Phase 3 component library. Phase 5 needs to set values directly without animation, then Phase 8 will re-add a polished version.
**How to avoid:** In Phase 5, remove the `animateDrawIn()` call and `onAppear`. Set animated values directly from the input values. Keep the animation infrastructure (Animatable conformance) so Phase 8 can re-enable it.
**Warning signs:** Gauge appearing with animation when it should be instant.

### Pitfall 7: Consistency Metric Definition
**What goes wrong:** "Consistency" could be misinterpreted as "data consistency" or "matching data sources". Per CONTEXT.md it specifically means: "percentage of tracks where BOTH genre AND year are filled -- fully processed tracks".
**Why it happens:** Ambiguous term without explicit definition.
**How to avoid:** Implement as: `tracksWithBoth = tracks.filter { $0.genre != nil && !$0.genre!.isEmpty && $0.year != nil }.count; consistencyCoverage = Double(tracksWithBoth) / Double(total)`.
**Warning signs:** Percentage not matching user expectations.

### Pitfall 8: Empty Genre String vs nil
**What goes wrong:** Some tracks have `genre = ""` (empty string) which should be treated the same as `genre = nil` for coverage metrics.
**Why it happens:** MusicKit may return an empty string for tracks without a genre.
**How to avoid:** Always check `track.genre != nil && !track.genre!.isEmpty` (or use the existing `.nilIfEmpty` extension on String).
**Warning signs:** Genre coverage showing higher than actual tagged tracks.

## Code Examples

### HeroGauge Color and Layout Update
```swift
// Updated GaugeLayer colors per CONTEXT.md
private enum GaugeLayer: CaseIterable, Sendable {
    case genre, year, consistency

    var color: Color {
        switch self {
        case .genre: Ayu.purple        // Was: Ayu.accent
        case .year: Ayu.info           // Was: Ayu.success
        case .consistency: Ayu.accent  // Was: Ayu.info
        }
    }
}
```

### Stacked Arc Layout (close radii with shadow)
```swift
// Stacked arcs: very close radii (2pt gap) with shadow between layers
private let arcLineWidth: CGFloat = 16
private let arcGap: CGFloat = 2  // Was 6 -- much closer for "stacked" feel

// Each arc gets a subtle drop shadow for z-separation
ArcShape(progress: animated, radius: radius, lineWidth: arcLineWidth)
    .stroke(layer.color, style: StrokeStyle(lineWidth: arcLineWidth, lineCap: .butt))
    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
```

### PersistedMetricsSnapshot Model
```swift
// Services/Persistence/SwiftData/PersistedMetricsSnapshot.swift
@Model
public final class PersistedMetricsSnapshot {
    public var totalTracks: Int
    public var tracksWithGenre: Int
    public var tracksWithYear: Int
    public var tracksWithBoth: Int
    public var tracksNeedingGenre: Int
    public var tracksNeedingYear: Int
    public var recentlyAdded: Int
    public var timestamp: Date

    public init(
        totalTracks: Int,
        tracksWithGenre: Int,
        tracksWithYear: Int,
        tracksWithBoth: Int,
        tracksNeedingGenre: Int,
        tracksNeedingYear: Int,
        recentlyAdded: Int,
        timestamp: Date = .now
    ) { /* assign all */ }

    public var genreCoverage: Double {
        totalTracks > 0 ? Double(tracksWithGenre) / Double(totalTracks) : 0
    }

    public var yearCoverage: Double {
        totalTracks > 0 ? Double(tracksWithYear) / Double(totalTracks) : 0
    }

    public var consistencyCoverage: Double {
        totalTracks > 0 ? Double(tracksWithBoth) / Double(totalTracks) : 0
    }
}
```

### Two-Phase Loading in DashboardView
```swift
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    let onNavigate: (NavigationCategory) -> Void

    // Injected from parent
    let tracks: [Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let isLoadingTracks: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch viewModel.loadingState {
                case .shimmer:
                    shimmerContent
                case .permissionDenied:
                    permissionDeniedView
                case .emptyLibrary:
                    emptyLibraryView
                default:
                    liveContent
                }
            }
        }
        .onAppear {
            viewModel.loadCachedMetrics(from: metricsSnapshot)
        }
        .task(id: tracks.count) {
            viewModel.refreshFromLive(tracks: tracks)
        }
    }
}
```

### Adaptive Card Grid
```swift
private var metricsSection: some View {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 180, maximum: 280))],
        spacing: Spacing.md
    ) {
        MetricCard(
            label: "Need Genre",
            value: viewModel.metrics.tracksNeedingGenre.formatted(),
            trend: viewModel.genreTrend,
            onTap: { onNavigate(.update) }
        )
        MetricCard(
            label: "Need Year",
            value: viewModel.metrics.tracksNeedingYear.formatted(),
            trend: viewModel.yearTrend,
            onTap: { onNavigate(.update) }
        )
        MetricCard(
            label: "Recently Added",
            value: viewModel.metrics.recentlyAdded.formatted(),
            trend: viewModel.recentTrend,
            onTap: { onNavigate(.browse) }
        )
    }
}
```

### Soft Quick Action Design
```swift
// Quick action with neutral tone per CONTEXT.md
struct DashboardQuickAction: View {
    let category: String      // "Genre", "Year"
    let count: Int
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                if count > 0 {
                    // "Genre . 327 untagged"
                    Text("\(category) . \(count.formatted()) untagged")
                        .font(AppFont.body)
                        .foregroundStyle(Ayu.fgPrimary)
                } else {
                    // Zero state with checkmark
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Ayu.success)
                        Text("All \(category.lowercased())s tagged")
                            .font(AppFont.body)
                            .foregroundStyle(Ayu.fgSecondary)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
            }
        }
        .buttonStyle(.plain)
    }
}
```

### Relative Timestamp Footer
```swift
private var timestampFooter: some View {
    HStack {
        Spacer()
        if case let .cached(lastUpdated) = viewModel.loadingState {
            Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgMuted)
        }
        Spacer()
    }
}
```

## State of the Art

| Old Approach (Current) | New Approach (Phase 5) | Impact |
|-------------------------|------------------------|--------|
| GaugeView (full circle, 2 rings, App target) | HeroGauge (half-circle, 3 stacked arcs, SharedUI) | Visual redesign, component reuse |
| No cache -- "0 tracks" on cold launch | SwiftData PersistedMetricsSnapshot loaded first | Never shows "0 tracks" |
| MetricCard without trends | MetricCard with trend arrows + hover delta | Progressive disclosure of change data |
| QuickActionButton with "Fix Now!" urgency | Soft neutral quick actions with counts | Calm observatory feel per design philosophy |
| Top Genres on Dashboard | Removed (moved to Reports in Phase 7) | Cleaner Dashboard layout |
| No loading states | Shimmer placeholders + progress text (>3s) | First-launch experience |
| Fixed 3-column card row | LazyVGrid with adaptive reflow | Responsive to window resize |

**Deprecated/replaced:**
- `GaugeView.swift` (App/Views/Components/) -- replaced by HeroGauge from SharedUI. Delete file.
- `topGenresSection` in DashboardView -- moved to Reports (Phase 7).

## Data Flow Architecture

### Launch Sequence
```
App Launch
  |
  v
MainView.loadTracks() [async]
  |
  +---> DashboardView.onAppear
  |       |
  |       v
  |     viewModel.loadCachedMetrics(snapshot)  [sync, instant]
  |       |
  |       v
  |     UI shows cached data (or shimmer if nil)
  |
  v
MusicKit.fetchAllTracks() completes
  |
  v
DashboardView.task(id: tracks.count)
  |
  v
viewModel.refreshFromLive(tracks)  [sync, O(n) single pass]
  |
  +---> Save new PersistedMetricsSnapshot [async]
  |
  v
UI updates with live data
```

### Metrics Snapshot Lifecycle
1. On first launch: no snapshot exists -> shimmer state
2. After first successful scan: snapshot saved to SwiftData
3. On subsequent launches: snapshot loaded immediately -> cached state
4. After background scan completes: snapshot updated, previous snapshot becomes trend baseline
5. Trend = compare current metrics to previous snapshot values

## Open Questions

1. **Where should PersistedMetricsSnapshot be saved?**
   - What we know: It should be in Services/Persistence/SwiftData/ alongside PersistedTrack
   - What's unclear: Should it be a single-row model (always upsert) or keep history for trend tracking?
   - Recommendation: Single-row model with a separate `previousTotalTracks`, `previousTracksNeedingGenre`, etc. fields for the last-known values. Simpler than maintaining a history table, and we only need one previous scan for trends.

2. **How does the snapshot get saved after a scan?**
   - What we know: DashboardViewModel computes metrics from tracks array
   - What's unclear: ViewModel is in App target, SwiftData store is in Services. Need a bridge.
   - Recommendation: Pass a `saveSnapshot` closure from AppDependencies/MainView to DashboardViewModel, or let MainView handle saving directly after tracks load. Keep ViewModel decoupled from Services.

3. **Should MainView's loadTracks also save to SwiftData?**
   - What we know: MainView already calls `reader.fetchAllTracks()` and stores result in `@State tracks`
   - What's unclear: Currently tracks are only held in memory. Saving to SwiftDataTrackStore on every launch seems expensive for 38K tracks.
   - Recommendation: Only save the metrics snapshot (7 integers + timestamp), not all 38K tracks to SwiftData on every launch. The metrics snapshot is the only thing needed for cached-first Dashboard display.

## Sources

### Primary (HIGH confidence)
- Existing codebase: HeroGauge.swift, StatCard.swift, ShimmerPlaceholder.swift, DashboardView.swift, DashboardViewModel.swift, DesignTokens.swift, AyuColors.swift
- Existing codebase: PersistedTrack.swift, SwiftDataTrackStore.swift, ModelContainerFactory.swift, MusicLibraryReader.swift
- Existing codebase: MainView.swift, AppDependencies.swift, Track.swift, Protocols.swift
- CONTEXT.md: All locked decisions verified against codebase feasibility

### Secondary (MEDIUM confidence)
- [Apple Developer Docs - Managing model data](https://developer.apple.com/documentation/SwiftUI/Managing-model-data-in-your-app) - @Observable + SwiftUI patterns
- [SwiftUI-Shimmer package](https://github.com/markiv/SwiftUI-Shimmer) - v1.5.1 already in project
- [SwiftData Architecture Patterns 2025](https://azamsharp.com/2025/03/28/swiftdata-architecture-patterns-and-practices.html) - SwiftData best practices

### Tertiary (LOW confidence)
- None -- all findings verified against codebase or official docs

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in project, no new dependencies
- Architecture: HIGH -- patterns verified against existing codebase structure (PersistedTrack model, DashboardViewModel, MainView data flow)
- Pitfalls: HIGH -- drawn from project CLAUDE.md pitfalls + actual code analysis (ModelContainerFactory schema, HeroGauge colors, arc layout)
- HeroGauge modifications: HIGH -- existing code fully analyzed, changes are well-scoped (colors, gap, shadow, click callback)
- SwiftData metrics snapshot: HIGH -- pattern follows existing PersistedTrack model exactly

**Research date:** 2026-02-23
**Valid until:** 2026-03-23 (stable tech, all existing in project)
