# Domain Pitfalls: macOS SwiftUI UI/UX Redesign

**Domain:** macOS SwiftUI music app redesign — 38K+ track library, custom dark/light theme, NavigationSplitView, half-circle gauge, batch selection
**Researched:** 2026-02-22
**Confidence:** HIGH (most findings verified with Apple Developer Forums, WWDC, or multiple independent sources)

---

## Critical Pitfalls

Mistakes that cause rewrites, regressions, or fundamental UX breakage.

---

### Pitfall 1: LazyVStack Grows Forever — Use List for 2,271+ Artists

**What goes wrong:** The redesigned Browse view uses `LazyVStack` inside a `ScrollView` for the artist list, believing "lazy" means it recycles off-screen views. It does not. `LazyVStack` only defers creation — views are never destroyed. With 2,271 artists (each with name, count badge, health ratio), scrolling to the bottom takes 52 seconds vs 5 seconds for `List`. Memory usage spirals as every artist row stays in memory.

**Why it happens:** The name "lazy" implies efficient rendering. SwiftUI documentation doesn't clearly warn that `LazyVStack` has no recycling — it only grows in size.

**Consequences:** macOS scroll is already slower than iOS. Hacking with Swift forums documented: "create a List with a few hundred rows (anything over 100 gets pretty bad)." At 2,271 artists, `LazyVStack` is unusable. The 78 hangs vs 4.6 hangs (List) benchmark is damning.

**Warning signs:**
- Frame rate drops when scrolling past 200 artists
- Memory grows proportionally to how far down you scroll
- Profiler shows `LazyVStack` layout work accumulating over time

**Prevention strategy:**
- Use `List` with `Section` for all artist/album/track lists — it uses AppKit-backed recycling
- Keep `LazyVStack` only for simple, bounded lists (top genres: 5-10 items, quick actions)
- For the album list within a selected artist (typically 5-30 albums), either `List` or `LazyVStack` is fine
- For the track list within a selected album (typically 5-20 tracks), `LazyVStack` is acceptable

**Phase:** Browse redesign (Phase 1 of redesign)

---

### Pitfall 2: macOS 15 Scroll Hit-Test Regression — 85% CPU in `_hitTestForEvent`

**What goes wrong:** On macOS 15 Sequoia, trackpad scrolling in SwiftUI apps is visibly chunky. Instruments shows 85% of execution time inside `_hitTestForEvent`. Scrollbar-dragging is smooth; trackpad momentum scrolling is not. This affects `List`, `ScrollView`, and `LazyVStack` equally.

**Why it happens:** Apple introduced a regression in macOS 15 scroll handling. Feedback was filed and marked "Potential fix identified — for a future OS update." As of macOS 15.2, the issue persists.

**Consequences:** The Dashboard's `ScrollView` and the Browse `List` will feel choppy on macOS 15, regardless of how well the SwiftUI code is written. Users on macOS 14 Sonoma have buttery smooth scrolling on the same code.

**Warning signs:**
- Trackpad scrolling noticeably stutters but scrollbar dragging is smooth
- Instruments shows `_hitTestForEvent` dominating the CPU flame graph
- Issue appears only on macOS 15, not 14

**Prevention strategy:**
- Apply `.contentShape(.rect)` explicitly on scrollable row views — reduces unnecessary complex hit-test geometry calculations
- Avoid complex nested gesture recognizers inside scroll areas (no `DragGesture` inside `List` rows)
- Use `.allowsHitTesting(false)` on purely decorative overlay layers (gradient overlays, glow effects)
- Profile early on macOS 15 to establish baseline; this may improve in a dot release

**Phase:** All phases — apply contentShape defensively everywhere from the start

---

### Pitfall 3: `@Observable` View Models Recreated When `@State` Is Omitted

**What goes wrong:** During incremental redesign, a new view initializes its `@Observable` view model inline: `let viewModel = MyViewModel()`. Because it's not wrapped in `@State`, SwiftUI recreates the view model on every parent re-render. For `DashboardView`, this means `viewModel.refresh(tracks:)` fires repeatedly, triggering metric recomputation on 38K tracks each time the parent `MainView` rebuilds.

**Why it happens:** `@Observable` objects don't self-manage lifecycle. Only `@State` guarantees single initialization. `@StateObject` (the old pattern) was explicit about this; `@Observable + @State` is less obvious.

**Consequences:**
- Repeated expensive computations (genre fill %, year fill %, top genres aggregation) on every sidebar navigation
- Memory leaks from lingering model instances
- Notification observers registered multiple times

**Warning signs:**
- Network requests or heavy computations fire more than expected (logging reveals this)
- Dashboard metrics recalculate on every sidebar tap even when tracks haven't changed
- `task(id:)` fires unexpectedly

**Prevention strategy:**
```swift
// WRONG — recreated on every parent rebuild
struct DashboardView: View {
    let viewModel = DashboardViewModel()  // not @State!
}

// CORRECT — stable lifecycle
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
}
```
- Every view model must be `@State private var` — enforce this in code review
- For injected (shared) view models, use `@Environment` or pass as `let` (already-stable reference)
- The existing `MainView` passes tracks and dependencies correctly — new views must follow the same pattern

**Phase:** All view model introductions — enforce from first new view

---

### Pitfall 4: `preferredColorScheme` Does Not Affect All macOS Components

**What goes wrong:** The manual theme override (Light / Dark / System toggle in Settings) uses `.preferredColorScheme(.dark)` on the top-level view. Sheets, `DatePicker`, `confirmationDialog`, and any new windows (like a future export dialog) ignore this modifier and render with the system appearance. The app looks inconsistent — main content is dark, but a sheet is light.

**Why it happens:** `preferredColorScheme` propagates through SwiftUI's environment but does not pierce presentation boundaries on macOS. Native AppKit components inside SwiftUI ignore SwiftUI's environment entirely.

**Consequences:**
- SettingsView (sheet-based or separate window) renders in wrong theme
- Any future export dialog will mismatch
- On macOS, this affects more surfaces than on iOS due to multiple window types

**Warning signs:**
- Sheet appears in system theme when app is set to override
- Any `DatePicker` or `ColorPicker` inside the app ignores the override

**Prevention strategy:**
- Use `NSApp.appearance` instead of (or in addition to) `preferredColorScheme`:
  ```swift
  // In AppDelegate or theme manager
  func applyTheme(_ theme: AppTheme) {
      switch theme {
      case .dark:
          NSApp.appearance = NSAppearance(named: .darkAqua)
      case .light:
          NSApp.appearance = NSAppearance(named: .aqua)
      case .system:
          NSApp.appearance = nil  // follows system
      }
  }
  ```
- Call this in addition to `preferredColorScheme` to cover both SwiftUI and AppKit surfaces
- Store theme preference in `@AppStorage` and react with `onChange`
- The existing `NSColor(name:dynamicProvider:)` pattern in `AyuColors.swift` is correct for adaptive colors — the bug is at the override layer, not the color definition layer

**Phase:** Design system / Settings redesign (early — before any sheet is built)

---

### Pitfall 5: Three-Column `NavigationSplitView` Shows Detail Column When Irrelevant

**What goes wrong:** The current `MainView` uses a three-column `NavigationSplitView` (sidebar / content / detail). On Dashboard, Update, and Reports screens, the detail column shows "Select a Track" — an empty, wasted third column. This is the exact problem described in the PROJECT.md screenshots. The `.balanced` style keeps all columns visible, which is wrong for most screens.

**Why it happens:** `NavigationSplitView` doesn't know which screens need a detail column. The `columnVisibility` API provides coarse control (`.doubleColumn` vs `.all`) but the transitions between them can feel abrupt if done with animation.

**Consequences:** Detail column occupies ~30% of window width on screens where it adds zero value. Dashboard hero gauge is cramped. Reports charts have less horizontal space.

**Warning signs:**
- The `updateColumnVisibility()` pattern already exists in `MainView` — the mechanism is correct but only triggers on `selectedCategory` and `selectedTrack` changes
- The detail column layout wasted on non-Browse screens

**Prevention strategy:**
- Extend `updateColumnVisibility()` to default to `.doubleColumn` for all non-Browse screens
- Only show `.all` (three columns) when `selectedCategory == .browse && selectedTrack != nil`
- The current code already does this — validate the new designs don't break this invariant
- For the half-circle gauge hero, ensure the content column gets maximum width when detail is hidden
- Avoid using `.prominentDetail` — it does not work on macOS

**Phase:** Dashboard and Browse redesign (verify at the start of each screen)

---

### Pitfall 6: Search Filtering 38K Tracks Blocks Main Thread

**What goes wrong:** The search field in Browse filters 38,085 tracks by artist name synchronously on the main actor. Even with 300ms debounce, the actual filter computation (iterating 38K tracks, string matching, re-grouping into sections) happens synchronously when `debouncedSearchText` updates. On each keystroke after the debounce, the UI freezes for 50-200ms.

**Why it happens:** `Task { }` in SwiftUI inherits the `@MainActor` context from its declaration site unless explicitly escaped. A `task(id:)` modifier runs on the main actor by default.

**Consequences:** Browse search feels laggy on a 38K library. Users expect instant results.

**Warning signs:**
- Noticeable stutter after the debounce fires (not during typing, but after the delay)
- Profiler shows main thread work during filter computation
- `task(id:)` blocks on a computed property that iterates `tracks`

**Prevention strategy:**
```swift
// WRONG — still on MainActor
.task(id: debouncedSearchText) {
    // This still runs on the main actor
    filteredSections = computeSections(searchText: debouncedSearchText)
}

// CORRECT — explicitly move work off main actor
.task(id: debouncedSearchText) {
    let result = await Task.detached(priority: .userInitiated) {
        computeSections(searchText: debouncedSearchText, tracks: self.tracks)
    }.value
    filteredSections = result
}
```
- Mark `computeSections` as a free function (not on `@MainActor`) to make offloading explicit
- The existing `BrowseView` debounce (300ms, `Task.sleep`, cancellation check) is the right skeleton — the computation needs to move off main actor
- Pre-compute artist groupings once when tracks load (already done via `task(id: tracks.count)`) — search only needs to filter the pre-computed data, which is much faster

**Phase:** Browse redesign — critical before any search implementation

---

## Moderate Pitfalls

Mistakes that degrade UX or require non-trivial fixes.

---

### Pitfall 7: List Row Highlight Conflicts with Custom Row Backgrounds

**What goes wrong:** A custom `ArtistRow` with a `RoundedRectangle` background uses `.listRowBackground(Color.clear)` to suppress the system row background. When selected, the system draws a blue selection overlay behind the custom background — the result is a blue tinge bleeding through or a double-layer visual artifact. On macOS, `List` selection behavior is more opinionated than iOS.

**Why it happens:** SwiftUI `List` on macOS uses AppKit's selection rendering (NSTableView) underneath. The selection highlight is drawn at the row level, below the SwiftUI view. Custom backgrounds sitting on top create z-order conflicts.

**Warning signs:**
- Selected row shows system blue AND custom background color simultaneously
- Foreground text auto-turns white on selection (system behavior) conflicting with custom foreground colors
- Row looks different when selected vs not selected in unexpected ways

**Prevention strategy:**
- Detect selection state via environment and render the entire row background conditionally:
  ```swift
  @Environment(\.isEnabled) private var isEnabled  // not directly useful
  // Instead, pass selection state explicitly or use List's selection binding
  ```
- Use `.listRowBackground` with the selection-aware color:
  ```swift
  .listRowBackground(
      isSelected ? Ayu.selection : Color.clear
  )
  ```
- Where `isSelected` is passed in from the parent based on the selection `Set<Track.ID>`
- Avoid placing a `RoundedRectangle` background inside a `List` row — the row IS the container; use `.listRowBackground` instead

**Phase:** Browse redesign — establish pattern before building artist rows

---

### Pitfall 8: ForEach with Unstable IDs Causes Flash/Jump on Filter Updates

**What goes wrong:** Browse sections are computed as `[LetterSection]` structs with `var id: String { letter }`. If `computedSections` returns a new array reference on every call (even with identical content), SwiftUI treats each section as replaced — causing flash animations during search. The artist rows inside sections use `var id: String { name }` which is stable, but if the section grouping recomputes from a closure that's called in `body`, the outer `ForEach` gets confused.

**Why it happens:** SwiftUI diffs based on `id` values, not reference equality. If an `@State` variable holding sections is reassigned with structurally identical content, SwiftUI still diffs the IDs. But if sections are computed inline in `body` (not cached in `@State`), every render creates new values.

**Warning signs:**
- Sections flash/dissolve on every keystroke even with debounce
- Scroll position resets when search term changes
- Animation artifacts (sections appearing to slide in from nowhere)

**Prevention strategy:**
- Always store filtered results in `@State var filteredSections: [LetterSection]` — never compute inline in `body`
- Assign `filteredSections` only when the result actually changes (compare `searchText` first)
- The current `BrowseView` architecture (`filteredSections` computed property that calls into `GroupingCache`) is correct — ensure it's stored in `@State` and only updated asynchronously

**Phase:** Browse redesign — affects how view state is structured from day one

---

### Pitfall 9: Half-Circle Gauge Using `Canvas` Has No Hit Testing

**What goes wrong:** The redesigned Dashboard gauge is a large, interactive hero element. If implemented with SwiftUI `Canvas` for drawing performance, taps on the gauge segments don't register — `Canvas` has no accessibility tree and no hit testing for individual drawn elements. Users can't tap a segment to get detail.

**Why it happens:** `Canvas` is an immediate-mode drawing surface. It draws pixels but knows nothing about which pixel belongs to which logical element. Hit testing requires a view tree.

**Warning signs:**
- Tapping the genre arc does nothing when the view is built with `Canvas`
- VoiceOver cannot see individual ring segments
- Gesture recognizers attached to `Canvas` fire for the whole canvas, not specific arcs

**Prevention strategy:**
- The current `GaugeView` uses `Circle().trim()` via SwiftUI `Shape` API — this is correct. Shapes ARE views with proper hit testing. Keep this approach.
- For interactive overlays (segment tap to show detail popover), place transparent `Circle().trim()` shapes as invisible tap targets over the visual arcs:
  ```swift
  // Invisible tap target on top of the visual arc
  Circle()
      .trim(from: 0, to: genreFraction)
      .stroke(Color.clear, lineWidth: outerLineWidth)
      .contentShape(Circle().trim(from: 0, to: genreFraction))
      .rotationEffect(.degrees(-90))
      .onTapGesture { showGenreDetail = true }
  ```
- `Canvas` is suitable only for purely decorative elements (background glow, shimmer effects) where interactivity is never needed
- The existing `GaugeView` with `Circle().trim()` can handle 280pt size with full animation at 60fps without needing Canvas

**Phase:** Dashboard redesign — validate before making the gauge interactive

---

### Pitfall 10: `AngularGradient` Gauge Seam at Zero/Full

**What goes wrong:** When `genreFillPercent` is very close to 0% or 100%, the `AngularGradient` used in the arc arcs shows an artifact: the gradient start and end colors create a visible "seam" where the trimmed circle wraps around. At 100%, the full ring has a color discontinuity at the top (12 o'clock position).

**Why it happens:** `AngularGradient` interpolates around 360 degrees. `Circle().trim(from: 0, to: 1.0)` is a full circle — the gradient start at 0° and end at 360° can create a visible boundary if the start/end colors differ significantly.

**Warning signs:**
- The current `genreGradient` goes from `Ayu.purple` to `Ayu.purple.opacity(0.7)` — mild seam at 100%
- More visible if the gradient colors diverge (e.g., purple to orange)

**Prevention strategy:**
- For 100% fill, switch to a simple `stroke` color (no gradient) to avoid the seam
- Add a small `startAngle` offset: end the gradient slightly before 360° for the full-ring case
- Or use `LinearGradient` rotated to match the arc instead of `AngularGradient` — linear gradients have no seam

**Phase:** Dashboard redesign — verify visually at 0%, 50%, 99%, 100%

---

### Pitfall 11: NSColor Dynamic Provider Color Not Updating When Manually Overriding Theme

**What goes wrong:** `AyuColors.swift` creates adaptive colors using `NSColor(name:dynamicProvider:)` — this responds to system appearance changes automatically. But when using `NSApp.appearance` to force a theme override (Pitfall 4's fix), `NSColor` dynamic providers may not fire a change notification if the SwiftUI view hasn't been invalidated. Colors appear "stuck" after a theme toggle until the view is scrolled or interacted with.

**Why it happens:** `NSColor.dynamicProvider` fires when `NSAppearance.currentDrawingAppearance` changes. When `NSApp.appearance` is set, AppKit notifies views that need to redraw, but SwiftUI's `@Observable` state doesn't automatically know that color tokens have changed.

**Warning signs:**
- After toggling from Dark to Light in Settings, some UI areas remain dark until scrolled
- The main window background switches instantly but card backgrounds lag

**Prevention strategy:**
- Pair `NSApp.appearance = ...` with publishing a `@Published` / `@State` `themeVersion: Int` that increments on change
- Use this as a `task(id: themeVersion)` dependency on any view that embeds `NSColor`-backed colors
- Alternatively, use SwiftUI's `.environment(\.colorScheme, ...)` in addition to `NSApp.appearance` to force SwiftUI to re-render the hierarchy
- The `Color.adaptive(light:dark:)` extension in `AyuColors.swift` is based on `NSColor(name:dynamicProvider:)` — verify this invalidates correctly after `NSApp.appearance` changes by testing the toggle manually

**Phase:** Design system / Settings — validate before shipping theme toggle

---

### Pitfall 12: Multi-Select via `Set<Track.ID>` Works in `List`, Not in Custom `LazyVStack` Rows

**What goes wrong:** Shift+click and Cmd+click for range/individual selection are built into SwiftUI `List` when using the `List(selection:)` initializer with a `Set<ID>` binding. If Browse moves to a custom `LazyVStack` layout (perhaps for visual density reasons), all built-in keyboard modifier selection behavior vanishes — it must be re-implemented manually.

**Why it happens:** The multi-select keyboard behavior is baked into the AppKit `NSTableView` that backs SwiftUI `List`. Custom views have none of this.

**Warning signs:**
- Cmd+click adds nothing to selection
- Shift+click selects only the clicked item, not a range
- Selection set is always 0 or 1 items

**Prevention strategy:**
- Keep artist/album/track browsing in `List` with `List(tracks, selection: $selectedTrackIDs)` — get multi-select for free
- If visual customization of rows conflicts with `List` styling, use `.listRowBackground()` and `.listRowSeparator()` modifiers rather than abandoning `List`
- The `Table` view also supports `Set`-based multi-select with full keyboard modifier support — consider for track-list level where columns (title, artist, album, year, genre) add value
- Do NOT implement artist-level batch selection via `List` multi-select — the UX requirement is "select entire artist" which means a separate checkbox/toggle in the artist row, not multi-select of the artist row itself

**Phase:** Browse redesign — decide List vs Table vs custom before implementing any row

---

### Pitfall 13: Incremental Redesign Breaking Existing View Model State

**What goes wrong:** During screen-by-screen redesign, a new `DashboardView` is written to replace the prototype. The new view has a different `DashboardViewModel` with renamed or reordered properties. The old `NavigationCategory` enum, `MainView` state, and `AppDependencies` wiring all depend on the prototype view's public interface. The app compiles but the new view doesn't receive data (tracks, dependencies) because the connection point changed.

**Why it happens:** Incremental replacement means the old wiring (in `MainView`) must still match the new view's init signature. During transition, multiple breaking changes accumulate.

**Warning signs:**
- New view shows empty state even though `tracks` are loaded
- `task(id: tracks.count)` fires but `viewModel.refresh(tracks:)` receives zero tracks
- Type mismatches appear in `MainView.contentView`

**Prevention strategy:**
- Replace one screen at a time — complete it fully before starting the next
- When redesigning a view, keep the init parameters identical (`let tracks: [Track]`, `let onNavigate:`) even if the internal implementation changes
- Add a `#Preview` with real-looking data that exercises the full rendering path before wiring into `MainView`
- Run the full Xcode build after each screen replacement (not just the package build) to catch wiring regressions immediately
- The `MainView.contentView` switch is the seam — test it manually for every case after each new view lands

**Phase:** All redesign phases — enforce as a protocol before starting each screen

---

## Minor Pitfalls

Issues that cause friction but have straightforward fixes.

---

### Pitfall 14: Hardcoded Colors Bypass the Ayu Design System

**What goes wrong:** During rapid prototyping of new components, a color is hardcoded: `.foregroundStyle(.white)`, `.background(Color(hex: 0x1A1F29))`, or `.opacity(0.3)` on a color token that already has semantic opacity. These bypass the Ayu system and break light mode.

**Prevention:**
- All colors must come from `Ayu.*` tokens
- Light mode review is mandatory before marking any screen done — SwiftUI previews make this trivial with `colorScheme` environment override
- `SwiftLint` can be extended with a custom rule to flag `Color(red:green:blue:)` and `Color(hex:)` outside `AyuColors.swift`

**Phase:** All phases — zero tolerance from day one

---

### Pitfall 15: Window Minimum Size Not Set — Toolbar Items Overflow

**What goes wrong:** The redesigned toolbar has more items (search, filter toggle, sync status). On a small window (e.g., 700pt wide), toolbar items move to an overflow chevron menu. SwiftUI has no API to prioritize which items stay visible or to set minimum toolbar item visibility.

**Prevention:**
- Set a window minimum size that guarantees all toolbar items fit: `windowResizability(.contentMinSize)` or `.frame(minWidth: 900, minHeight: 600)` on the window
- Test at the minimum width before shipping any new toolbar items
- If items must overflow gracefully, use `ToolbarItemGroup` with a single item that expands into a popover — this gives control over the overflow behavior

**Phase:** Design system — set minimum window dimensions before first toolbar changes

---

### Pitfall 16: `contentTransition(.opacity)` and `animation(value:)` Fight During Navigation

**What goes wrong:** `MainView` applies `.contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: selectedCategory)`. If the new view has internal `withAnimation` calls that run immediately on appear (like the gauge spring animation), two animation systems collide — the gauge enter animation runs simultaneously with the cross-fade, producing janky opacity + spring layering.

**Prevention:**
- Defer `onAppear` animations by one frame: `DispatchQueue.main.async { withAnimation(...) { } }` or use `.task { try? await Task.sleep(for: .milliseconds(50)) }` before starting internal animations
- Alternatively, use `.animation(nil)` on the gauge container during the navigation transition and re-enable after the cross-fade completes
- The current `GaugeView.onAppear` spring animation already has this risk when navigating to Dashboard — test it during Browse → Dashboard → Browse transitions

**Phase:** Dashboard redesign — test cross-fade + gauge animation interaction immediately

---

### Pitfall 17: Ayu Colors in Light Mode Have Low Contrast for Accessibility

**What goes wrong:** The Ayu light palette uses `fgPrimary: hex(0x5C6166)` on `bgPrimary: hex(0xFCFCFC)`. The contrast ratio is approximately 4.2:1 — just below the WCAG AA threshold of 4.5:1 for normal text. Secondary text (`fgSecondary: hex(0x8A9199)` on white) is approximately 2.9:1 — fails AA even for large text. Artist names in the Browse list, metric card values, and chart labels all use these tokens.

**Warning signs:**
- macOS Accessibility Inspector shows contrast warnings in light mode
- Text appears visually "light" on light backgrounds — readable in dark rooms, not in sunlight

**Prevention:**
- Darken `fgPrimary` light variant to at least `hex(0x4A4F55)` (4.7:1 on white)
- Darken `fgSecondary` light variant to at least `hex(0x636B74)` (4.5:1 on white)
- Verify all Ayu token combinations with a contrast calculator before shipping
- Support macOS "Increase Contrast" accessibility setting by providing high-contrast variants in the asset catalog for any colors defined there

**Phase:** Design system — fix tokens before they propagate across all new views

---

### Pitfall 18: `task(id:)` Recomputing on Every Parent Render Due to Unstable ID

**What goes wrong:** `DashboardView` uses `.task(id: tracks.count)` to trigger `viewModel.refresh(tracks:)`. If `tracks` array is replaced with a new allocation on every `MainView` render (even with the same tracks), `.task(id: tracks.count)` will only refire when count changes — which is correct. But if the ID is `tracks` itself (or a hashValue of the array), it refires on every render and triggers expensive recomputation.

**Prevention:**
- Always use a stable, scalar ID for `task(id:)`: `tracks.count`, a timestamp, or a specific version counter
- Never use `tracks` (an array) or `tracks.hashValue` as a task ID — array `hashValue` is not stable across renders
- For the metric cache use case, consider a dedicated `libraryVersion: Int` counter that increments only when library content actually changes (library sync delivers this via `LibrarySyncService`)

**Phase:** Dashboard redesign — define the refresh trigger contract before implementing

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|---|---|---|
| Dashboard (gauge hero) | Pitfall 9 (Canvas hit testing) | Use Shape API, not Canvas; add explicit tap targets |
| Dashboard (gauge hero) | Pitfall 16 (animation collision) | Defer gauge animation 50ms after content transition |
| Dashboard (metrics cache) | Pitfall 3 (@Observable lifecycle) | `@State private var viewModel` — enforce everywhere |
| Dashboard (metrics cache) | Pitfall 18 (task ID instability) | Use `tracks.count` or library version counter |
| Browse (artist list) | Pitfall 1 (LazyVStack grows forever) | Use `List` with `Section` for artist list |
| Browse (artist list) | Pitfall 7 (row highlight conflict) | Use `listRowBackground` for selection state |
| Browse (search) | Pitfall 6 (main thread filter) | `Task.detached` for filter computation |
| Browse (search) | Pitfall 8 (ForEach ID instability) | Store sections in `@State`, never compute inline |
| Browse (batch select) | Pitfall 12 (multi-select in custom views) | Keep `List(selection:)` for built-in Shift/Cmd |
| Design system (theme toggle) | Pitfall 4 (preferredColorScheme incomplete) | Add `NSApp.appearance` alongside SwiftUI modifier |
| Design system (theme toggle) | Pitfall 11 (NSColor not invalidating) | Publish `themeVersion` counter, use as `task(id:)` |
| Design system (colors) | Pitfall 17 (contrast in light mode) | Audit all Ayu light tokens against WCAG AA |
| Design system (colors) | Pitfall 14 (hardcoded colors) | Zero tolerance; SwiftLint custom rule if needed |
| All screens (macOS 15) | Pitfall 2 (hitTestForEvent regression) | Apply `contentShape(.rect)` on row views proactively |
| All screens (NavigationSplitView) | Pitfall 5 (detail column wastes space) | Only show `.all` on Browse with selected track |
| All screens (incremental) | Pitfall 13 (view model wiring breaks) | Keep init signatures stable; build after each screen |
| All screens (window) | Pitfall 15 (toolbar overflow) | Set minimum window width ≥ 900pt before toolbar work |

---

## Sources

**Performance:**
- [List or LazyVStack — Fatbobman](https://fatbobman.com/en/posts/list-or-lazyvstack/) — HIGH confidence (detailed benchmarks)
- [SwiftUI List performance is slow on macOS — Apple Developer Forums](https://developer.apple.com/forums/thread/650238) — HIGH confidence (Apple forums)
- [SwiftUI ScrollView performance in macOS 15 — Apple Developer Forums](https://developer.apple.com/forums/thread/764264) — HIGH confidence (hitTestForEvent confirmed)
- [Tuning Lazy Stacks and Grids — Wesley Matlock / Medium](https://medium.com/@wesleymatlock/tuning-lazy-stacks-and-grids-in-swiftui-a-performance-guide-2fb10786f76a) — MEDIUM confidence

**NavigationSplitView:**
- [NavigationSplitView's Hidden Trap — The Empathic Dev](https://theempathicdev.de/blog/advanced-navigation-split-view-bugs) — MEDIUM confidence
- [NavigationSplitView — Apple Developer Documentation](https://developer.apple.com/documentation/swiftui/navigationsplitview) — HIGH confidence

**Color Scheme / Theming:**
- [Reading and setting color scheme — NilCoalescing](https://nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/) — HIGH confidence
- [preferredColorScheme not affecting DatePicker — Hacking with Swift Forums](https://www.hackingwithswift.com/forums/swiftui/preferredcolorscheme-not-affecting-datepicker-and-confirmationdialog/11796) — HIGH confidence (confirmed issue)
- [Creating dynamic colors in SwiftUI — Jesse Squires](https://www.jessesquires.com/blog/2023/07/11/creating-dynamic-colors-in-swiftui/) — HIGH confidence

**State Management:**
- [SwiftUI's Observable macro is not a drop-in replacement — Jesse Squires](https://www.jessesquires.com/blog/2024/09/09/swift-observable-macro/) — HIGH confidence
- [Lifecycle of SwiftUI View — Swift Forums](https://forums.swift.org/t/lifecycle-of-swiftui-view-observable-vs-observableobject/69842) — HIGH confidence
- [SwiftUI View Models: Lifecycle Quirks — Medium](https://medium.com/the-swift-cooperative/swiftui-view-models-lifecycle-quirks-8dd967e84e31) — MEDIUM confidence

**Multi-Select:**
- [Multiple rows Selection in SwiftUI List — Sarunw](https://sarunw.com/posts/swiftui-list-multiple-selection/) — HIGH confidence
- [Enabling Selection on macOS — SerialCoder.dev](https://serialcoder.dev/text-tutorials/swiftui/enabling-selection-double-click-and-context-menus-in-swiftui-list-on-macos/) — HIGH confidence

**Canvas / Gauge:**
- [Advanced SwiftUI Animations Part 5: Canvas — SwiftUI Lab](https://swiftui-lab.com/swiftui-animations-part5/) — HIGH confidence
- [Mastering Canvas in SwiftUI — Swift with Majid](https://swiftwithmajid.com/2023/04/11/mastering-canvas-in-swiftui/) — HIGH confidence

**Search Performance:**
- [SwiftUI Tasks Blocking the MainActor — Use Your Loaf](https://useyourloaf.com/blog/swiftui-tasks-blocking-the-mainactor/) — HIGH confidence
- [Mastering the SwiftUI task Modifier — Fatbobman](https://fatbobman.com/en/posts/mastering_swiftui_task_modifier/) — HIGH confidence
