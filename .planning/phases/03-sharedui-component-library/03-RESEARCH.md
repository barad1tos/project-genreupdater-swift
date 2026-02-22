# Phase 3: SharedUI Component Library - Research

**Researched:** 2026-02-22
**Domain:** SwiftUI reusable components (macOS), custom Shape drawing, interaction states, shimmer loading
**Confidence:** HIGH

## Summary

This phase builds six new reusable SwiftUI components (HeroGauge, ArtistListRow, AlbumListRow, FilterChip, StatCard, SectionIndexBar) plus a ShimmerPlaceholder wrapper in the existing SharedUI package. The SharedUI package already contains a mature design token system (Spacing, Radius, AppFont, Shadow, Motion, Ayu colors), seven existing components (ConfidenceBadge, ProgressRing, EmptyStateView, TierBadge, PaywallOverlay, TrackRow, TrackDetailView), and Liquid Glass helpers. All new components accept plain data types (Double, String, Int) with no domain model dependencies. The only new external dependency is SwiftUI-Shimmer 1.5.1.

The primary technical challenges are: (1) drawing concentric half-circle arcs with animation using SwiftUI Path/Shape, (2) reliable hover detection on macOS using `.onHover`, and (3) integrating a Swift 5.3-toolchain dependency (SwiftUI-Shimmer) into a Swift 6 strict concurrency package.

**Primary recommendation:** Build each component as a standalone file with `#Preview` blocks, use existing DesignTokens/Ayu tokens exclusively, add SwiftUI-Shimmer via `@preconcurrency import Shimmer` to suppress concurrency warnings, and apply `.contentShape(.rect)` on all interactive rows proactively per the macOS 15 scroll regression decision.

<user_constraints>

## User Constraints (from CONTEXT.md)

### Locked Decisions

**HeroGauge:**
- Concentric arcs layout (like Apple Fitness rings): 3 half-circle arcs at different radii -- outer: genre, mid: year, inner: consistency
- Flat/butt caps on arc ends (not rounded) -- technical, minimalist look
- Medium arc width (14-18pt) -- balanced visual weight
- Subtle track background arc (semi-transparent 180-degree arc behind each layer showing the maximum)
- Ayu semantic colors: Genre = Ayu.accent (orange), Year = Ayu.success (green), Consistency = Ayu.info (blue)
- Center content is contextual/switchable: shows track count by default, shows layer-specific % coverage on hover over that arc
- Legend below gauge: colored dots + label + percentage for each layer (Genre 78% / Year 92% / Consistency 65%)
- Draw-in animation on appear: arcs fill from 0% to actual value when first shown
- API: accepts 3 Double values (0.0-1.0) for genre, year, consistency coverage + an Int for track count

**List Rows (ArtistListRow + AlbumListRow):**
- ArtistListRow content: name (left) + album count badge + track count badge (right). Example: "Radiohead  12a  247t"
- AlbumListRow content: title (left) + genre badge (if present) + year (right). Example: "OK Computer  [Rock]  1997"
- Badge font: SF Mono (monospaced) for numeric badges -- aligns in columns
- Row height: standard (44-48pt)
- No dividers between rows -- spacing only (like Doppler/Spotify)
- Hover state: leading accent bar (thin vertical Ayu.accent stripe on left) + light background fill (like Slack selected channel)
- Press state: scale down to 0.98x -- tactile iOS-like feedback
- Selected state: persistent accent bar + Ayu.accent.opacity(0.1) background -- stays after click, needed for multi-select in Phase 6
- .contentShape(.rect) on all rows for macOS 15 scroll regression fix

**SectionIndexBar:**
- Smart mode: only shows letters that have corresponding artists (not full A-Z)
- Vertical bar on right side of list, drag scrolls to section
- Will handle 2,271 artists across ~26 alphabetical sections

**StatCard:**
- Floating card style: shadow.card + Ayu.bgSecondary background + rounded corners (Radius.md)
- Content: label (small text) + big number + mini progress bar below
- Mini progress bar animates width smoothly on data updates
- Hover state: shadow elevation (card -> elevated) + Ayu.accent border appears simultaneously
- Press state: scale down 0.98x (consistent with list rows)

**FilterChip:**
- Squared tag style: Radius.sm rounding (not capsule)
- Active state: Ayu.accent background + white text
- Inactive state: border only (Ayu.fgMuted.opacity(0.3)) + Ayu.fgPrimary text
- Optional dismissable mode: shows xmark.circle for removing active filters
- Toggle animation: color cross-fade (~0.2s) between active/inactive states
- Press state: scale down 0.98x

### Claude's Discretion
- Exact spacing values within components (use DesignTokens Spacing)
- Font sizes for labels, numbers, badges (use DesignTokens AppFont)
- SectionIndexBar letter styling and spacing
- HeroGauge exact arc radii and gaps between concentric rings
- Progress bar height and corner radius inside StatCard
- Accessibility: VoiceOver labels and traits for interactive elements

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope

</user_constraints>

<phase_requirements>

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DSYS-03 | All interactive elements show hover, press, and focus states | Every component (HeroGauge, ArtistListRow, AlbumListRow, FilterChip, StatCard, SectionIndexBar) must implement `.onHover` for hover states, `ButtonStyle` or `.scaleEffect` for press states, and `.focusable()` with `.focused()` for keyboard focus. Pattern documented in Architecture Patterns section. |

</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI | macOS 15+ | All UI rendering | Apple framework, already used project-wide |
| SwiftUI-Shimmer | 1.5.1 | Loading shimmer effect | Lightweight (single file), 3K+ stars, macOS 10.15+ support, locked decision in ROADMAP |

### Supporting (Already in SharedUI)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| DesignTokens | (internal) | Spacing, Radius, AppFont, Shadow, Motion | ALL spacing/sizing/animation values |
| AyuColors | (internal) | Color palette | ALL color references |
| Core | (internal) | Track, Tier, AppFeature types | Only for existing components (TrackRow, TierBadge, PaywallOverlay) -- new components must NOT depend on Core models |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SwiftUI-Shimmer | Custom shimmer modifier | More code, edge cases with gradient masking; Shimmer is battle-tested |
| Custom Shape for arcs | UIBezierPath wrapper | SwiftUI Path/Shape is native, no bridging needed |
| NSTrackingArea for hover | .onHover modifier | .onHover occasionally misses mouseExited on fast cursor; acceptable for this use case since rows are large targets |

**Installation (Package.swift addition):**
```swift
dependencies: [
    .package(path: "../Core"),
    .package(url: "https://github.com/markiv/SwiftUI-Shimmer.git", from: "1.5.1"),
],
targets: [
    .target(
        name: "SharedUI",
        dependencies: [
            "Core",
            .product(name: "Shimmer", package: "SwiftUI-Shimmer"),
        ],
        // ...
    ),
]
```

## Architecture Patterns

### Recommended File Structure
```
Packages/SharedUI/Sources/SharedUI/
├── Theme/                   # (existing) DesignTokens, AyuColors, AppearanceMode
├── Components/              # NEW — reusable primitives
│   ├── HeroGauge.swift      # Half-circle concentric arc gauge
│   ├── ArtistListRow.swift  # Artist row with count badges
│   ├── AlbumListRow.swift   # Album row with genre/year
│   ├── FilterChip.swift     # Toggle chip with active/inactive states
│   ├── StatCard.swift       # Floating metric card
│   ├── SectionIndexBar.swift # Alphabetical scroll index
│   └── ShimmerPlaceholder.swift # Shimmer loading wrapper
├── ConfidenceBadge.swift    # (existing)
├── ProgressRing.swift       # (existing)
├── EmptyStateView.swift     # (existing)
├── TierBadge.swift          # (existing)
├── PaywallOverlay.swift     # (existing)
├── TrackRow.swift           # (existing)
├── TrackDetailView.swift    # (existing)
├── SharedUI.swift           # (existing) Module namespace
├── Charts/                  # (existing)
└── Reports/                 # (existing)
```

### Pattern 1: Plain-Data Component API
**What:** Components accept only primitive types (Double, String, Int, Bool), never domain models
**When to use:** All new Phase 3 components
**Why:** Keeps SharedUI free from domain coupling; screens compose by mapping model -> primitives
**Example:**
```swift
// Good: plain data
public struct HeroGauge: View {
    let genreCoverage: Double    // 0.0-1.0
    let yearCoverage: Double     // 0.0-1.0
    let consistencyCoverage: Double // 0.0-1.0
    let trackCount: Int

    public init(
        genreCoverage: Double,
        yearCoverage: Double,
        consistencyCoverage: Double,
        trackCount: Int
    ) { /* ... */ }
}

// Bad: domain model dependency
public struct HeroGauge: View {
    let tracks: [Track]  // NO — couples to Core
}
```

### Pattern 2: Hover + Press + Selected State Trio
**What:** Consistent interaction pattern across all interactive components
**When to use:** Every interactive component in this phase
**Example:**
```swift
public struct ArtistListRow: View {
    // Data
    let name: String
    let albumCount: Int
    let trackCount: Int
    let isSelected: Bool

    // Interaction state
    @State private var isHovered = false
    @State private var isPressed = false

    public var body: some View {
        HStack {
            // Leading accent bar (visible on hover or selected)
            RoundedRectangle(cornerRadius: 2)
                .fill(Ayu.accent)
                .frame(width: 3)
                .opacity(isHovered || isSelected ? 1 : 0)

            // Content...
        }
        .frame(height: 44)
        .background(backgroundFill)
        .contentShape(.rect) // macOS 15 scroll fix
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                isHovered = hovering
            }
        }
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(Motion.curveFast, value: isPressed)
    }

    private var backgroundFill: some View {
        RoundedRectangle(cornerRadius: Radius.xs)
            .fill(isSelected ? Ayu.accent.opacity(0.1) :
                  isHovered ? Ayu.bgTertiary.opacity(0.5) :
                  Color.clear)
    }
}
```

### Pattern 3: Draw-In Arc Animation
**What:** Animate arc trim from 0 to actual value on appear
**When to use:** HeroGauge entrance animation
**Example:**
```swift
// Custom Shape for a half-circle arc
struct ArcShape: Shape {
    var progress: Double  // 0.0-1.0, animatable
    var startAngle: Angle = .degrees(180)
    var endAngle: Angle = .degrees(360)

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY) // bottom center
        let radius = min(rect.width, rect.height * 2) / 2
        let sweepAngle = (endAngle - startAngle).radians * progress
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle + .radians(sweepAngle),
            clockwise: false
        )
        return path
    }
}

// Usage in HeroGauge
@State private var animatedProgress: Double = 0

var body: some View {
    ZStack {
        // Background track arc (full 180 degrees, semi-transparent)
        ArcShape(progress: 1.0)
            .stroke(Ayu.accent.opacity(0.15), style: StrokeStyle(
                lineWidth: 16, lineCap: .butt
            ))

        // Value arc (animated)
        ArcShape(progress: animatedProgress)
            .stroke(Ayu.accent, style: StrokeStyle(
                lineWidth: 16, lineCap: .butt // flat caps per decision
            ))
    }
    .onAppear {
        withAnimation(.spring(duration: 0.8, bounce: 0.15)) {
            animatedProgress = genreCoverage
        }
    }
}
```

### Pattern 4: SectionIndexBar with ScrollViewReader
**What:** Vertical letter bar that drives programmatic scrolling
**When to use:** SectionIndexBar component, consumed by Browse view in Phase 6
**Example:**
```swift
public struct SectionIndexBar: View {
    let letters: [String] // Only letters with content (smart mode)
    let onLetterSelected: (String) -> Void

    @GestureState private var dragLetter: String?

    public var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ayu.fgSecondary)
                    .frame(width: 16, height: 14)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = letterIndex(for: value.location.y)
                    if index < letters.count {
                        onLetterSelected(letters[index])
                    }
                }
        )
    }
}

// Consumer (Phase 6) wraps List in ScrollViewReader:
// ScrollViewReader { proxy in
//     HStack {
//         List { ... sections with .id(letter) ... }
//         SectionIndexBar(letters: availableLetters) { letter in
//             withAnimation { proxy.scrollTo(letter, anchor: .top) }
//         }
//     }
// }
```

### Pattern 5: SwiftUI-Shimmer Integration
**What:** Import Shimmer with @preconcurrency for Swift 6 compatibility
**When to use:** ShimmerPlaceholder component
**Example:**
```swift
@preconcurrency import Shimmer

/// Placeholder view with shimmer animation for loading states.
public struct ShimmerPlaceholder: View {
    let shape: ShimmerShape

    public enum ShimmerShape: Sendable {
        case rectangle(width: CGFloat, height: CGFloat)
        case circle(diameter: CGFloat)
        case gauge // half-circle shape matching HeroGauge
        case card  // StatCard-shaped
    }

    public init(shape: ShimmerShape) {
        self.shape = shape
    }

    public var body: some View {
        placeholderContent
            .shimmering()
    }
}
```

### Anti-Patterns to Avoid
- **Importing Core models in new components:** All new components must use plain types. TrackRow/TierBadge depend on Core because they predate this rule -- do not follow that pattern.
- **Raw color/spacing values:** Never use `Color.gray` or literal padding numbers. Always use `Ayu.*` and `Spacing.*` tokens.
- **`.animation(_, value:)` without `.motionAnimation`:** For user-facing animations that persist (not entrance-only), use `motionAnimation` to respect Reduce Motion. Entrance animations (HeroGauge draw-in) can use raw `.animation` since they only fire once.
- **Rounded lineCap on HeroGauge:** Decision explicitly requires `.butt` (flat) caps for a technical/minimalist look. The existing ProgressRing uses `.round` -- do not copy that style.
- **Missing `.contentShape(.rect)`:** Every interactive row/card MUST include this modifier. Without it, macOS 15 has a scroll regression where `.onHover` and tap targets break on List rows.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Shimmer/skeleton loading | Custom gradient animation | SwiftUI-Shimmer `.shimmering()` | Edge cases with RTL, reduce motion, gradient banding |
| Adaptive colors | Manual `@Environment(\.colorScheme)` checks | `Ayu.*` tokens (use `Color.adaptive`) | Already implemented, handles NSColor-based dark mode correctly |
| Shadow elevation | Raw `.shadow()` calls | `.ayuShadow(Shadow.subtle)` | Consistent tinting, single source of truth |
| Animation durations | Literal `0.2` / `0.3` values | `Motion.curveFast`, `Motion.curveDefault` | Consistency + reduce motion support |
| SF Mono font | `.system(.body, design: .monospaced)` | `AppFont.mono` or `.system(.caption, design: .monospaced)` | Use AppFont when body size, custom size for badges |

**Key insight:** The design token system (DesignTokens.swift + AyuColors.swift) is comprehensive. Every visual property -- spacing, radius, color, shadow, animation curve -- has a token. New components should reference zero raw values.

## Common Pitfalls

### Pitfall 1: SwiftUI-Shimmer Swift 6 Concurrency Warnings
**What goes wrong:** SwiftUI-Shimmer uses swift-tools-version 5.3 with no Sendable annotations. Importing it in a Swift 6 strict concurrency module produces warnings/errors.
**Why it happens:** The Shimmer ViewModifier and its types are not marked Sendable.
**How to avoid:** Use `@preconcurrency import Shimmer`. This suppresses diagnostics for types from that module that lack Sendable conformance.
**Warning signs:** Build errors mentioning "Shimmer" + "Sendable" or "cannot be used in concurrent code".

### Pitfall 2: .onHover Not Firing on mouseExit with Fast Cursor
**What goes wrong:** When users move the mouse quickly across rows, `.onHover` may not call the closure with `false` (exit), leaving rows stuck in hover state.
**Why it happens:** Known SwiftUI behavior on macOS -- tracking areas don't always fire exit events at high velocity.
**How to avoid:** For this phase, use `.onHover` directly (it works well enough for 44pt-high rows). If issues emerge in testing, wrap in an `NSViewRepresentable` with explicit `NSTrackingArea`. The row height (44-48pt) provides a large enough target to mitigate this.
**Warning signs:** Multiple rows showing hover state simultaneously.

### Pitfall 3: Arc Angle Coordinate System
**What goes wrong:** SwiftUI/Core Graphics angles start at 3 o'clock (right) and go clockwise. Developers often assume 12 o'clock (top) as 0 degrees.
**Why it happens:** Math convention vs CG convention. For a half-circle gauge opening upward, the start angle should be `180 degrees` (left, or 9 o'clock) and end angle `360 degrees` (right, or 3 o'clock).
**How to avoid:** Use `.degrees(180)` to `.degrees(360)` for a top-opening half-circle. Test visually in previews before wiring animation.
**Warning signs:** Arcs drawing downward or starting from unexpected positions.

### Pitfall 4: Forgetting `public` on Types and Inits
**What goes wrong:** Components build fine in SharedUI but fail when consumed from App target with "cannot find type" errors.
**Why it happens:** SPM enforces access control. Default is `internal`.
**How to avoid:** Mark every struct, init, enum, and body property as `public`. Follow the existing ConfidenceBadge/ProgressRing pattern.
**Warning signs:** Build errors only when building the App target, not SharedUI alone.

### Pitfall 5: animatableData Conformance for Custom Shapes
**What goes wrong:** Arc shapes don't animate smoothly -- they jump from 0 to final value.
**Why it happens:** SwiftUI needs `animatableData` on Shape to interpolate between values during animation.
**How to avoid:** Implement `var animatableData: Double` on ArcShape. For multiple animated properties, use `AnimatablePair`.
**Warning signs:** Shapes snap to final value instead of smoothly transitioning.

### Pitfall 6: StatCard Shadow Transition
**What goes wrong:** Shadow change on hover looks jarring or produces a "double shadow" flash.
**Why it happens:** Animating between two different `ShadowToken` values means all four properties (color, radius, x, y) must transition smoothly.
**How to avoid:** Use `.ayuShadow()` with a ternary on hover state and wrap in `motionAnimation`. Both `Shadow.subtle` and `Shadow.elevated` use the same `x: 0` and tint-based colors, so they interpolate well.
**Warning signs:** Shadow flickering or abrupt size jumps during hover transition.

### Pitfall 7: SectionIndexBar Gesture Coordinate Space
**What goes wrong:** Drag gesture Y position doesn't map correctly to letter indices, especially after scrolling.
**Why it happens:** DragGesture reports coordinates in the gesture's coordinate space, not the screen. If the SectionIndexBar is inside a scrolling container, coordinates shift.
**How to avoid:** Place SectionIndexBar outside/overlay on the List, not inside it. Use `.coordinateSpace` if needed. Calculate letter index from gesture Y relative to bar height.
**Warning signs:** Selecting wrong letters, especially at top/bottom of the bar.

## Code Examples

Verified patterns from the existing codebase:

### Existing Hover Pattern (from PaywallOverlay structure)
```swift
// No hover in PaywallOverlay, but ConfidenceBadge shows the badge pattern:
public struct ConfidenceBadge: View {
    let confidence: Double
    public init(confidence: Double) { self.confidence = confidence }
    public var body: some View {
        Text(formattedPercentage)
            .font(.caption2)
            .bold()
            .foregroundStyle(badgeForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor, in: .capsule)
            .accessibilityLabel("\(Int(clampedConfidence * 100)) percent confidence")
    }
}
```

### SF Mono Badge Pattern (for ArtistListRow/AlbumListRow)
```swift
// Monospaced numeric badges that align in columns
Text("\(albumCount)a")
    .font(.system(.caption, design: .monospaced))
    .foregroundStyle(Ayu.fgSecondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Ayu.bgTertiary, in: RoundedRectangle(cornerRadius: Radius.xs))
```

### Existing Animation Token Usage
```swift
// Source: DesignTokens.swift
// Motion.curveFast = .easeInOut(duration: 0.2) -- for hover/press
// Motion.curveDefault = .easeInOut(duration: 0.3) -- for content transitions
// Use motionAnimation for persistent animations:
.motionAnimation(Motion.curveFast, value: isHovered, reduceMotion: reduceMotion)
```

### FilterChip Toggle Pattern
```swift
public struct FilterChip: View {
    let label: String
    let isActive: Bool
    let isDismissable: Bool
    let onTap: () -> Void
    let onDismiss: (() -> Void)?

    @State private var isPressed = false
    @State private var isHovered = false

    public var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(label)
                .font(AppFont.caption)

            if isDismissable, isActive {
                Image(systemName: "xmark.circle")
                    .font(.caption2)
                    .onTapGesture { onDismiss?() }
            }
        }
        .foregroundStyle(isActive ? .white : Ayu.fgPrimary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isActive ? Ayu.accent : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(
                            isActive ? Color.clear : Ayu.fgMuted.opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .onHover { isHovered = $0 }
        .animation(Motion.curveFast, value: isActive) // cross-fade ~0.2s
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `ObservableObject` | `@Observable` macro | Swift 5.9+ / macOS 14+ | Components don't need ObservableObject; use @State for local state |
| `.contentShape(Rectangle())` | `.contentShape(.rect)` | macOS 15+ | Shorter syntax, same effect; project targets macOS 15 |
| Raw `.animation()` | `motionAnimation(_:value:reduceMotion:)` | Phase 1 (DesignTokens) | Respects Reduce Motion setting |
| Manual Sendable annotations | `@preconcurrency import` | Swift 5.6+ | Clean suppression for pre-Swift 6 dependencies |
| StrokeStyle with round caps | `.butt` caps for gauges | Decision | Flat/technical look vs rounded Fitness-ring look |

**Deprecated/outdated:**
- `Rectangle()` as a shape type: Use `.rect` (the shape value) introduced in macOS 15
- `ObservableObject` + `@Published`: Not needed for view-local state; `@State` suffices for all Phase 3 components

## Open Questions

1. **SwiftUI-Shimmer + macOS 26 Liquid Glass interaction**
   - What we know: Shimmer uses gradient masking. Liquid Glass uses system-level glass effects.
   - What's unclear: Whether `.shimmering()` renders correctly on glass-backed surfaces in macOS 26.
   - Recommendation: Test in Xcode 26 beta when available. For now, ShimmerPlaceholder should use opaque `Ayu.bgSecondary` background, not glass.

2. **SectionIndexBar letter density at scale**
   - What we know: 2,271 artists across ~26 alphabetical sections. If all 26 letters are present, each letter gets ~14pt height in a typical sidebar.
   - What's unclear: Whether non-Latin script artists (CJK, Cyrillic) create additional sections beyond A-Z + #.
   - Recommendation: Support a generic `[String]` input. Let the consumer (Phase 6) compute which section headers exist. Default to `#` for non-alphabetic. Size each letter at 14pt height -- this accommodates up to ~40 sections in a standard sidebar.

3. **HeroGauge center content hover detection per arc**
   - What we know: Center shows track count by default, layer-specific % on hover over that arc.
   - What's unclear: Detecting which specific arc the cursor is over requires hit-testing on individual arc shapes.
   - Recommendation: Use one `.onContinuousHover` (macOS 13+) to get cursor position, then calculate which arc ring the cursor falls within based on distance from center. This avoids needing separate tracking areas per arc.

## Sources

### Primary (HIGH confidence)
- Existing codebase: `Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift` -- all token definitions
- Existing codebase: `Packages/SharedUI/Sources/SharedUI/Theme/AyuColors.swift` -- all color tokens
- Existing codebase: `Packages/SharedUI/Sources/SharedUI/ConfidenceBadge.swift` -- badge component pattern
- Existing codebase: `Packages/SharedUI/Sources/SharedUI/ProgressRing.swift` -- circular arc animation pattern
- [Apple: Path.addArc](https://developer.apple.com/documentation/swiftui/path/addarc(center:radius:startangle:endangle:clockwise:transform:)) -- arc drawing API
- [Apple: ScrollViewReader](https://developer.apple.com/documentation/swiftui/scrollviewreader) -- programmatic scrolling
- [SwiftUI-Shimmer Package.swift](https://github.com/markiv/SwiftUI-Shimmer) -- version 1.5.1, swift-tools-version 5.3, macOS 10.15+

### Secondary (MEDIUM confidence)
- [SwiftUI Activity Rings](https://swdevnotes.com/swift/2021/create-activity-rings-in-swiftui/) -- concentric ring pattern reference
- [Reliable SwiftUI hover workaround](https://gist.github.com/importRyan/c668904b0c5442b80b6f38a980595031) -- NSTrackingArea fallback if .onHover proves unreliable
- [@preconcurrency import](https://www.avanderlee.com/concurrency/preconcurrency-checking-swift/) -- Swift 6 migration for pre-concurrency dependencies
- [SwiftUI contentShape](https://swiftwithmajid.com/2021/12/03/customizing-view-content-shape-in-swiftui/) -- interaction shape customization

### Tertiary (LOW confidence)
- HeroGauge `.onContinuousHover` for per-arc detection -- needs validation; API available since macOS 13 but usage for geometric hit-testing is uncommon in examples

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- SwiftUI-Shimmer verified at 1.5.1, API confirmed, swift-tools-version 5.3 compatible with Swift 6 via @preconcurrency
- Architecture: HIGH -- patterns derived directly from existing SharedUI codebase (ConfidenceBadge, ProgressRing, DesignTokens)
- Pitfalls: HIGH -- most pitfalls sourced from project CLAUDE.md (contentShape, public access, strict concurrency) and verified SwiftUI behavior
- HeroGauge per-arc hover: MEDIUM -- `.onContinuousHover` approach is sound but untested in this specific geometry

**Research date:** 2026-02-22
**Valid until:** 2026-03-22 (stable SwiftUI patterns, no fast-moving dependencies)
