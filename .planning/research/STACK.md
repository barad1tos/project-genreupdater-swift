# Technology Stack: GenreUpdater UI/UX Redesign

**Project:** GenreUpdater macOS — UI/UX Redesign Milestone
**Researched:** 2026-02-22
**Research scope:** UI tooling only — backend (Core, Services) is complete and unchanged.

---

## Existing Foundation (Do Not Replace)

These decisions are already made and locked in. The redesign builds on top of them.

| Layer | Technology | Version | Status |
|-------|-----------|---------|--------|
| Language | Swift 6 (strict concurrency) | 6.0 | Locked |
| UI Framework | SwiftUI | macOS 15+ | Locked |
| Navigation | NavigationSplitView | macOS 13+ | Locked |
| State | @Observable macro | macOS 14+ | Locked |
| Charts | Swift Charts (Apple framework) | macOS 13+ | Already used in ReportsCharts |
| Color system | Ayu palette + DesignTokens | — | Already built |
| Progress UI | ProgressRing (custom Circle trim) | — | Already built |
| SharedUI | Swift Package, macOS 15 min | — | Locked |

The SharedUI package already contains:
- `AyuColors.swift` — full adaptive light/dark palette
- `DesignTokens.swift` — Spacing, Radius, AppFont scales + `applyLiquidGlass()` helpers
- `ProgressRing.swift` — circular ring with animated trim
- `ReportsCharts.swift` — bar + line charts via Swift Charts

---

## Theming: Dark + Light Mode

**Recommendation: Extend the existing Ayu system. No third-party theming library needed.**

**Confidence: HIGH** — Verified against Apple docs and existing codebase.

### How it Works Today

`AyuColors.swift` already implements the correct pattern: `Color.adaptive(light:dark:)` wraps `NSColor` with an appearance-based closure. This gives proper macOS system integration — colors re-resolve when the user switches appearance at the OS level without any SwiftUI refresh needed.

### What to Add for the Redesign

**Theme preference persistence** (`@AppStorage`):

```swift
enum AppearancePreference: String, CaseIterable {
    case system, light, dark
}

// In App entry point:
@AppStorage("appearancePreference") var appearancePreference: AppearancePreference = .system

WindowGroup { MainView() }
    .preferredColorScheme(appearancePreference.colorScheme)
```

`preferredColorScheme(_:)` is the correct API — the deprecated `colorScheme(_:)` environment override must not be used (it only affects a subtree, not the window).

**Custom non-Ayu backgrounds**: For Spotify/Doppler-style deep dark backgrounds (not system background), override with explicit Ayu tokens at the window level:

```swift
// In MainView body:
.background(Ayu.bgPrimary)
.foregroundStyle(Ayu.fgPrimary)
```

This ensures custom colors show on top of the system material while remaining theme-correct.

### What NOT to Do

- Do not install a theming library (ColorTokensKit-Swift, etc.) — Ayu already covers the token layer.
- Do not use `.colorScheme()` environment override on subtrees — it breaks toolbar and title bar appearance.
- Do not use `Color("Named", bundle: nil)` asset-catalog colors for new tokens — the `Color.adaptive(light:dark:)` helper is already more reliable for SPM packages (asset catalogs in SPM require explicit bundle passing that is easy to break).

---

## Custom Gauge Component (Half-Circle Dashboard Hero)

**Recommendation: Build from scratch using SwiftUI shapes. Do NOT use GaugeKit or the native Gauge view.**

**Confidence: HIGH** — Built-in Gauge options verified; custom shape approach is the only path for the required design.

### Why Not the Native `Gauge` View

The built-in SwiftUI `Gauge` (macOS 13+) provides these styles:
- `linearCapacity` — horizontal bar only
- `accessoryCircular` — small watch-complication-style ring
- `accessoryCircularCapacity` — solid ring, watch-style
- No half-circle / speedometer style exists as a built-in

The watch-style `accessoryCircular*` styles are sized for complications and not resizable to a 280pt+ dashboard hero. Custom `GaugeStyle` via the protocol is possible but Apple's `GaugeStyleConfiguration` doesn't expose the geometry you need for layered arc rendering.

### Why Not GaugeKit

GaugeKit (github.com/antonmartinsson/GaugeKit) targets watchOS gauge complications. Its API is not designed for a multi-layer, large-format, macOS dashboard element. Last commit 2021.

### Recommended Pattern: Custom Shape + Circle Trim

The existing `ProgressRing` in SharedUI already demonstrates the correct approach. Extend it to a half-circle (180°) with multiple layered arcs:

```swift
struct HalfCircleGauge: View {
    let genrePercent: Double   // 0.0–1.0
    let yearPercent: Double    // 0.0–1.0
    let totalTracks: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            // Track (background arc)
            arc(trim: 0...1)
                .stroke(.quaternary, style: strokeStyle(width: 16))

            // Year arc (inner ring)
            arc(trim: 0...yearPercent)
                .stroke(Ayu.info.gradient, style: strokeStyle(width: 10))
                .animation(.spring(duration: 0.6), value: yearPercent)

            // Genre arc (outer ring)
            arc(trim: 0...genrePercent)
                .stroke(Ayu.accent.gradient, style: strokeStyle(width: 16))
                .animation(.spring(duration: 0.6), value: genrePercent)

            // Center label
            VStack(spacing: 4) {
                Text(totalTracks, format: .number)
                    .font(AppFont.display)
                Text("tracks")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
            .offset(y: size * 0.1)  // push down for half-circle visual center
        }
        .frame(width: size, height: size / 2 + size * 0.15)
    }

    private func arc(trim: ClosedRange<Double>) -> some Shape {
        Circle()
            .trim(from: trim.lowerBound / 2, to: trim.upperBound / 2)
            .rotation(.degrees(180))  // start from left
    }

    private func strokeStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round)
    }
}
```

The key technique: `Circle().trim(from: 0, to: value / 2)` with a 180° rotation gives a half-circle that fills from left to right. Multiple circles with different ring offsets (via padding) create the layered look.

**Animation**: Use `.animation(.spring(duration: 0.6, bounce: 0.15), value: percent)` on the trim for a satisfying elastic settle when data loads.

---

## Charts: Swift Charts (Apple Framework)

**Recommendation: Continue using Swift Charts (already in use). No third-party chart library needed.**

**Confidence: HIGH** — Swift Charts is already integrated in `ReportsCharts.swift`.

### What's Already Built

`ReportsCharts.swift` uses:
- `BarMark` with horizontal orientation for genre distribution
- `LineMark` + `AreaMark` with CatmullRom interpolation for change history
- `PointMark` for data highlights
- `.chartXAxisLabel`, `.chartYAxisLabel`, `.chartXAxis` with `AxisMarks`

### What the Redesign Adds

**Dashboard sparklines**: Use `AreaMark` or `LineMark` with a small `.frame(height: 40)` for inline trend indicators inside metric cards. Swift Charts handles this natively.

**Year histogram**: A `BarMark` with `x: .value("Decade", decade)` and `y: .value("Count", count)` gives a decade-distribution histogram. Add `.foregroundStyle(by: .value("Era", era))` for coloring by era.

**Custom chart styling** to match Ayu palette:

```swift
Chart { ... }
    .chartBackground { proxy in
        Ayu.bgSecondary.opacity(0.5)
    }
    .chartXAxis {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(Ayu.bgTertiary)
            AxisValueLabel().foregroundStyle(Ayu.fgSecondary)
        }
    }
```

### What NOT to Use

- `SwiftUICharts` (github.com/willdale/SwiftUICharts) — unnecessary given Swift Charts, and v3 is not released.
- `DSFSparkline` — only needed for AppKit-based targets; Swift Charts handles sparklines natively in SwiftUI.
- `ChartsOrg/Charts` (DGCharts) — the AppKit/UIKit wrapper library, completely inappropriate for SwiftUI.

---

## Shimmer / Skeleton Loading

**Recommendation: SwiftUI-Shimmer (markiv/SwiftUI-Shimmer). Single import, macOS compatible, zero dependencies.**

**Confidence: MEDIUM** — Library confirmed cross-platform (macOS, iOS, tvOS, watchOS, visionOS). Last verified active.

### Why This Library

- Adds `.shimmering()` as a single view modifier
- Pairs with `.redacted(reason: .placeholder)` for skeleton screens
- Supports light and dark mode automatically
- macOS compatible (not iOS-only)
- ~100 lines of code — auditable, no surprises
- Swift Package Manager: `https://github.com/markiv/SwiftUI-Shimmer`

### Usage Pattern

```swift
// In DashboardView while metrics are loading:
MetricCard(title: "Tracks", value: "38,085", ...)
    .redacted(reason: isLoading ? .placeholder : [])
    .shimmering(active: isLoading)
```

This prevents the "0 tracks" on launch problem — show redacted skeleton immediately, then animate in real data when the background delta scan completes.

### Alternative: No Library

Shimmer can be implemented in ~30 lines with a `LinearGradient` animated via `@State` offset. If the library adds friction (SwiftLint issues, version lag), drop it and implement inline. The pattern is well-documented.

---

## Animation

**Recommendation: Built-in SwiftUI animation APIs only. No third-party animation library.**

**Confidence: HIGH** — All required animation patterns are covered by built-in APIs.

### Available APIs (All macOS 15 Compatible)

| API | Use Case | Available Since |
|-----|----------|----------------|
| `.animation(.spring, value:)` | Data-driven transitions (gauge arcs, counters) | macOS 11 |
| `.withAnimation(.easeInOut)` | State-driven layout changes | macOS 11 |
| `matchedGeometryEffect` | Hero transitions between views (e.g., selected track expanding) | macOS 11 |
| `PhaseAnimator` | Multi-step sequences (loading → loaded → settled) | macOS 14 |
| `KeyframeAnimator` | Property-independent concurrent animations | macOS 14 |
| `.contentTransition(.numericText())` | Counter increments (track counts, percentages) | macOS 14 |
| `.contentTransition(.opacity)` | View content swaps | macOS 13 |
| `ScrollViewReader` + `.scrollTo` | Programmatic scroll (alphabet index) | macOS 11 |

### Recommended Patterns

**Gauge loading sequence** (PhaseAnimator):

```swift
enum LoadPhase: CaseIterable {
    case skeleton, populating, settled
}

PhaseAnimator(LoadPhase.allCases, trigger: hasData) { phase in
    HalfCircleGauge(...)
        .opacity(phase == .skeleton ? 0.3 : 1.0)
        .scaleEffect(phase == .skeleton ? 0.95 : 1.0)
} animation: { phase in
    switch phase {
    case .skeleton: .easeIn(duration: 0.2)
    case .populating: .spring(duration: 0.5, bounce: 0.2)
    case .settled: .easeOut(duration: 0.3)
    }
}
```

**View transitions** (content transition, already in MainView):

```swift
.contentTransition(.opacity)
.animation(.easeInOut(duration: 0.2), value: selectedCategory)
```

**Counter animations** (already used in ProgressRing):

```swift
Text(count, format: .number)
    .contentTransition(.numericText())
    .animation(.spring, value: count)
```

### What NOT to Use

No third-party animation library (Lottie, Rive, etc.) is needed or appropriate. Lottie is for playback of After Effects exports — not composited SwiftUI state animations. Rive requires a subscription and external tooling. The built-in APIs are sufficient and more maintainable.

---

## macOS-Specific Patterns

### NSVisualEffectView Bridging

**When to use**: The app uses custom Ayu backgrounds, not system materials, for the content area. `NSVisualEffectView` is only needed where a system material blur is explicitly desired — e.g., a floating panel, a search overlay, or the sidebar itself.

The sidebar already gets system material automatically via `listStyle(.sidebar)` — no bridging needed there.

**Pattern** (for custom floating panels only):

```swift
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
```

Usage: `.background(VisualEffectBlur(material: .sidebar))` on a floating search panel.

**The existing `applyLiquidGlass()` helper** in `DesignTokens.swift` already covers this for macOS 26+. For macOS 15 targets, use `VisualEffectBlur` as the fallback.

### Sidebar

**Keep the existing `listStyle(.sidebar)` approach.** It provides:
- System translucency
- Correct selection highlight
- Proper macOS sidebar spacing

For custom sidebar item styling:

```swift
Label(category.rawValue, systemImage: category.icon)
    .tag(category)
    .badge(count)  // macOS 14 — shows badge on sidebar items
```

**Column widths**: Already configured in MainView (`navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)`). Keep as-is.

**Do NOT** try to customize the sidebar background color via `.listRowBackground` on macOS — this conflicts with the system material and causes rendering artifacts. The Ayu custom background applies only to the content area, not the sidebar.

### Toolbar

The standard SwiftUI toolbar API covers all required cases:

```swift
.toolbar {
    ToolbarItem(placement: .principal) {
        // Center title / segmented control
    }
    ToolbarItem(placement: .primaryAction) {
        Button("Start Update", systemImage: "wand.and.stars") { ... }
            .keyboardShortcut(.return, modifiers: .command)
    }
}
.toolbarColorScheme(.dark, for: .windowToolbar)  // keeps toolbar text light in light mode
```

**`windowStyle(.titleBar)` + `windowToolbarStyle(.unified(showsTitle: false))`** for a unified toolbar that collapses the title bar — appropriate for the custom dark-first design.

### Keyboard Shortcuts

Native `.keyboardShortcut()` modifier handles all in-app shortcuts (Cmd+1–4 navigation, Cmd+Return to start update). Already wired via `FocusedValues` in MainView.

For any global shortcuts (app-level, not view-level), use `Commands` with `CommandMenu` or `CommandGroup` — no third-party library needed for this use case.

---

## Performance for 38K+ Item Lists

**Confidence: HIGH** — Verified against multiple benchmarks and the fatbobman.com deep-dive.

### Core Recommendation: `List` over `LazyVStack`

Benchmark data (2025, from medium.com/@chandra.welim):
- `List` scrolling to bottom of 10K items: **5.53 seconds**
- `LazyVStack` scrolling to bottom of 10K items: **52.3 seconds** (10x slower)
- `List` memory after scroll: **128.9 MB** vs `LazyVStack` **151.8 MB**

`List` uses a form of view recycling backed by `NSTableView` on macOS. `LazyVStack` does not recycle — it instantiates views lazily but never releases them.

For the Browse view (38K tracks grouped into ~2,271 artists), the hierarchy is:
1. Artist-level `List` with sections (2,271 items — small, fast)
2. Disclosure groups expand to album-level (manageable, user-triggered)
3. Track-level only shown within an artist (never all 38K at once)

**This makes 38K tracks manageable without pagination.**

### Section Headers with `List`

```swift
List(selection: $selectedTrack) {
    ForEach(artistGroups) { group in
        Section {
            ForEach(group.tracks) { track in
                TrackRow(track: track)
            }
        } header: {
            Text(group.artist)
                .font(.headline)
        }
    }
}
```

`List` on macOS automatically pins section headers (no `LazyVStack(pinnedViews:)` needed).

### Alphabet Index (ScrollViewReader + LazyVStack alternative)

For the alphabet sidebar jump: use `ScrollViewReader` with `.scrollTo(id:anchor:)` targeting section IDs. This is needed inside a `ScrollView` wrapper when using `LazyVStack`. For artist Browse specifically, use `List` with section IDs instead — `List` supports `ScrollViewReader` as well.

### Identity and Equatable for Performance

Ensure `TrackRow` is `Equatable` and uses `.equatable()`:

```swift
TrackRow(track: track)
    .equatable()  // skips re-render if track is unchanged
```

`Core.Track` is already `Sendable`. If it conforms to `Equatable` (verify), this is a free optimization.

### Search Debounce

Already implemented in the codebase (commit `8a5a58f` references "debounce search for 38K tracks"). Confirm the debounce fires on a background task and filters a pre-grouped `[String: [Track]]` dictionary rather than filtering the raw array on every keystroke.

### What NOT to Do

- Do not render all 38K `TrackRow` views at once — keep the drill-down Artist → Album → Track model
- Do not use `LazyVStack` for the primary list — use `List`
- Do not fetch-all on `List` selection change — filter the already-loaded in-memory array
- Do not apply `.animation` on the `List` itself (causes full list re-render) — apply animation on individual rows only

---

## Liquid Glass (macOS 26)

**Status: Progressive enhancement — already wired. No additional work needed.**

**Confidence: HIGH** — `DesignTokens.swift` already contains `applyLiquidGlass()` with `#available(macOS 26, *)` guard.

The existing helper:
```swift
public func applyLiquidGlass(in shape: some Shape = .rect(cornerRadius: Radius.md)) -> some View {
    if #available(macOS 26, *) {
        self.glassEffect(.regular, in: shape)
    } else {
        self  // no-op fallback on macOS 15
    }
}
```

**Usage guidance**: Apply to individual card elements and floating panels. Do NOT apply to the `NavigationSplitView` or `List` — they receive system-level glass automatically on macOS 26. Do NOT apply to full-screen background views — glass samples content behind the view, so applying it to a container gives undefined visual results.

**macOS 15 fallback**: The redesign should still look excellent on macOS 15. Use `Ayu.bgSecondary` card backgrounds with a subtle shadow as the macOS 15 equivalent:
```swift
.background(Ayu.bgSecondary, in: RoundedRectangle(cornerRadius: Radius.md))
.shadow(color: .black.opacity(0.12), radius: 4, y: 2)
```

---

## Empty States

**Recommendation: Use `ContentUnavailableView` (native, macOS 14+) as the baseline. Customize with action buttons.**

**Confidence: HIGH** — Available macOS 14.0+, app already uses it in MainView.

```swift
ContentUnavailableView {
    Label("No Genre Data Yet", systemImage: "chart.bar")
} description: {
    Text("Run an update to see genre distribution across your library.")
} actions: {
    Button("Go to Update") { onNavigate(.update) }
        .buttonStyle(.borderedProminent)
}
```

This matches Apple's system look while being customizable. Do NOT use a custom empty state view for this — `ContentUnavailableView` has proper accessibility, localization support, and adapts to macOS design automatically.

---

## Third-Party Libraries: Decision Table

| Library | Decision | Rationale | Confidence |
|---------|----------|-----------|------------|
| SwiftUI-Shimmer | ADD | Skeleton loading for 0-tracks-on-launch problem; macOS compatible; trivial to add | MEDIUM |
| Swift Charts | KEEP | Already in use, covers all chart needs | HIGH |
| GaugeKit | REJECT | watchOS-focused, outdated, wrong shape for design | HIGH |
| ColorTokensKit-Swift | REJECT | Ayu system already covers token needs | HIGH |
| DSFSparkline | REJECT | AppKit/UIKit only; Swift Charts handles sparklines | HIGH |
| SwiftUICharts | REJECT | Swift Charts is native and already integrated | HIGH |
| Lottie / Rive | REJECT | For prebuilt animation assets; not for SwiftUI state animations | HIGH |
| DSFToolbar | REJECT | SwiftUI toolbar API covers all required cases | HIGH |
| KeyboardShortcuts (sindresorhus) | REJECT | Global hotkeys not required; in-app shortcuts use native `.keyboardShortcut()` | HIGH |
| HotKey | REJECT | Same as KeyboardShortcuts — global activation not a requirement | HIGH |

### Only Addition: SwiftUI-Shimmer

```swift
// In SharedUI/Package.swift dependencies:
.package(url: "https://github.com/markiv/SwiftUI-Shimmer", from: "1.5.0")
// In target dependencies:
"Shimmer"
```

Verify current version at: https://github.com/markiv/SwiftUI-Shimmer/releases

---

## Environment-Based Theme Switching: Implementation Pattern

The complete theme switching pattern (not currently in the app):

```swift
// ThemeManager.swift in App target
@Observable
final class ThemeManager {
    @AppStorage("appearancePreference") var preference: AppearancePreference = .system

    var colorScheme: ColorScheme? {
        switch preference {
        case .system: nil  // nil = follow system
        case .light: .light
        case .dark: .dark
        }
    }
}

// GenreUpdaterApp.swift
@main struct GenreUpdaterApp: App {
    @State private var themeManager = ThemeManager()

    var body: some Scene {
        WindowGroup { MainView() }
            .preferredColorScheme(themeManager.colorScheme)
            .environment(themeManager)
    }
}
```

Settings view binds directly: `@Environment(ThemeManager.self) private var themeManager`.

---

## Recommended Package Manifest Change

SharedUI `Package.swift` — add Shimmer dependency only:

```swift
dependencies: [
    .package(path: "../Core"),
    .package(url: "https://github.com/markiv/SwiftUI-Shimmer", from: "1.5.0"),
],
targets: [
    .target(
        name: "SharedUI",
        dependencies: [
            "Core",
            .product(name: "Shimmer", package: "SwiftUI-Shimmer"),
        ],
        ...
    )
]
```

---

## Sources

- Apple Developer Documentation — ColorScheme: https://developer.apple.com/documentation/swiftui/colorscheme
- Apple Developer Documentation — Gauge/GaugeStyle: https://developer.apple.com/documentation/swiftui/gaugestyle
- Apple Developer Documentation — Swift Charts: https://developer.apple.com/documentation/Charts
- Apple Developer Documentation — ContentUnavailableView: https://developer.apple.com/documentation/swiftui/contentunavailableview
- Apple Developer Documentation — PhaseAnimator: https://developer.apple.com/documentation/swiftui/phaseanimator
- Apple Developer Documentation — glassEffect: https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- Apple Developer Documentation — NavigationSplitView: https://developer.apple.com/documentation/swiftui/navigationsplitview
- Apple Developer Documentation — ScrollPosition: https://developer.apple.com/documentation/swiftui/scrollposition
- SwiftUI List Performance (2025): https://medium.com/@chandra.welim/swiftui-list-performance-smooth-scrolling-for-10-000-items-c64116dc276f
- List or LazyVStack comparison: https://fatbobman.com/en/posts/list-or-lazyvstack/
- Optimize List responsiveness (large datasets): https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/
- SwiftUI-Shimmer library: https://github.com/markiv/SwiftUI-Shimmer
- Reading and setting color scheme in SwiftUI: https://nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/
- GaugeKit (rejected): https://github.com/antonmartinsson/GaugeKit
- Animating circular progress: https://cindori.com/developer/swiftui-animation-rings
- macOS NSVisualEffectView bridging: https://zachwaugh.com/posts/swiftui-blurred-window-background-macos
- PhaseAnimator guide: https://swift.mackarous.com/posts/2024/11/phase-animator/
- Liquid Glass reference (WWDC25): https://developer.apple.com/videos/play/wwdc2025/323/
- glassEffect on macOS 14 workarounds: https://www.klaritydisk.com/blog/building-liquid-glass-ui-macos
- @Observable macro performance: https://www.avanderlee.com/swiftui/observable-macro-performance-increase-observableobject/
- SwiftUI macOS 2024 notes: https://troz.net/post/2024/swiftui-mac-2024/
- macOS toolbar style reference: https://github.com/martinlexow/SwiftUIWindowStyles
