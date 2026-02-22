# Phase 1: Design System Foundation - Research

**Researched:** 2026-02-22
**Domain:** SwiftUI design tokens, WCAG color contrast, macOS window sizing
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Shadow Tokens**
- 4 elevation levels: subtle (cards), medium (dropdowns/popovers), elevated (modals/sheets), floating (drag-and-drop, tooltips)
- Color-tinted shadows using Ayu accent color for brand identity
- Inner shadows for pressed/inset button states
- Soft/diffuse spread style (Apple/Spotify aesthetic — large blur radius, wide spread)

**Motion Tokens**
- Duration scale in the 200-400ms range (Spotify-style — noticeable but not slow)
- Bezier easing curves (easeInOut/easeOut), not spring-based
- Motion applies to all 4 interaction types: hover states, press feedback, view transitions, data loading animations
- Respect macOS "Reduce motion" accessibility setting — disable animations when enabled, use instant transitions instead

**Color Corrections**
- fgPrimary (0x5C6166) must be darkened minimally to pass WCAG AA (≥4.5:1) on light background (0xFCFCFC) — preserve Ayu feel as close as possible
- fgSecondary (0x8A9199) also needs darkening — currently too faint in light mode for caption text
- Orange accent (0xFFAA33 light / 0xFFCC66 dark) is the primary brand color — do not change
- Dark mode (Ayu Mirage) palette is solid — no changes needed
- Ayu/Ayu Mirage color identity must be preserved throughout — extend, don't replace

**Spacing and Density**
- Current 10-step spacing scale (4→64pt) is adequate — no changes needed
- Standard list row density: 40-44pt height (Spotify/Doppler style, mouse-optimized)
- Current 8 font tokens (display through metricSmall) are sufficient — no additions
- Minimum window width: 900pt (prevents layout collapse)
- Default window size on first launch: 1280x800 (generous, close to Spotify default)

### Claude's Discretion
- Exact hex values for corrected fgPrimary and fgSecondary (within constraint: minimal darkening to pass WCAG AA)
- Exact shadow blur radius and offset values per elevation level
- Specific bezier curve parameters (control points)
- Whether to add a Spacing.row constant (40-44pt) or handle row height in components

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DSYS-02 | All UI components use extended design tokens including Shadow and Motion enums alongside existing Spacing/Radius/AppFont | Shadow enum with 4 elevation levels + view modifier; Motion enum with duration/easing tokens + reduce-motion guard; both live in DesignTokens.swift |
| DSYS-05 | Ayu/Ayu Mirage color palette is preserved and extended; light-mode contrast meets WCAG AA (≥4.5:1) | fgPrimary already passes (6.10:1); fgSecondary needs adjustment from #8A9199 to #697078 (4.89:1 on bgPrimary, 4.55:1 on bgSecondary); window constraint goes in GenreUpdaterApp.swift |
</phase_requirements>

## Summary

This phase makes three targeted additions to the SharedUI token layer: (1) Shadow and Motion enums in `DesignTokens.swift`, (2) color corrections to `AyuColors.swift` for light-mode WCAG compliance, and (3) window size enforcement in `GenreUpdaterApp.swift`. No new files need to be created — all changes land in existing files.

The color audit produced a critical finding: **fgPrimary (#5C6166) already passes WCAG AA at 6.10:1 on the primary background (#FCFCFC)** and 5.15:1 even on the darkest Ayu light surface (bgTertiary #E8E9EB). The user constraint noting "darkening needed" was based on stale information (STATE.md blocker noted ~4.2:1 which does not match actual computation). Only **fgSecondary (#8A9199 at 3.11:1)** requires correction — minimum fix is `#697078` which achieves 4.89:1 on bgPrimary and 4.55:1 on bgSecondary.

The Shadow and Motion enums follow a pure Swift namespace pattern (caseless enums with static lets) that matches the project's existing Spacing, Radius, and AppFont token style. SwiftUI's `.shadow()` modifier accepts color, radius, x, and y directly — no custom ViewModifier is required for the basic token application, but a `.ayuShadow(_ level:)` View extension is idiomatic and allows future changes to propagate automatically.

**Primary recommendation:** Add Shadow and Motion enums to `DesignTokens.swift`, fix only fgSecondary in `AyuColors.swift`, and update ContentView's `.frame` modifier from `minWidth: 800` to `minWidth: 900` with `defaultSize` added to the WindowGroup in `GenreUpdaterApp.swift`.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI (Apple) | macOS 15 | Token application via `.shadow()`, `.animation()`, `@Environment(\.accessibilityReduceMotion)` | Already in project; no external deps for token layer |
| AppKit (Apple) | macOS 15 | `NSColor` adaptive for color tokens (already used in AyuColors.swift) | Pattern established in AyuColors.swift `Color.adaptive()` |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| No additions needed | — | Phase 1 is pure Swift/SwiftUI | All token work uses existing Apple frameworks |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Static let in caseless enum | Struct with static let | Enums prevent instantiation — more correct for token namespaces; same pattern as existing Spacing/Radius/AppFont |
| `@Environment(\.accessibilityReduceMotion)` | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` | SwiftUI Environment is reactive to changes at runtime; NSWorkspace requires KVO or polling |
| `.shadow()` view modifier | `NSShadow` / `CALayer.shadowOpacity` | SwiftUI `.shadow()` is declarative and composable; CALayer requires UIViewRepresentable wrapper |

## Architecture Patterns

### Recommended Project Structure

No new files needed. All changes land in:

```
Packages/SharedUI/Sources/SharedUI/
├── Theme/
│   ├── DesignTokens.swift   ← Add Shadow + Motion enums here
│   └── AyuColors.swift      ← Fix fgSecondary hex value only
App/
└── GenreUpdaterApp.swift    ← Update .frame minWidth + add defaultSize
```

### Pattern 1: Caseless Enum Token Namespace

**What:** Swift caseless enums with `public static let` constants — prevents instantiation, groups related tokens, identical to existing Spacing/Radius/AppFont pattern.

**When to use:** Always for design token namespaces in this codebase.

**Example:**
```swift
// Matches the existing pattern in DesignTokens.swift
public enum Shadow {
    /// Cards, list rows — barely lifted off the surface.
    public static let subtle = ShadowToken(
        color: Ayu.accent.opacity(0.08),
        radius: 8,
        x: 0,
        y: 2
    )
    /// Dropdowns, popovers — clearly above content.
    public static let medium = ShadowToken(
        color: Ayu.accent.opacity(0.12),
        radius: 16,
        x: 0,
        y: 4
    )
    /// Modals, sheets — prominent elevation.
    public static let elevated = ShadowToken(
        color: Ayu.accent.opacity(0.16),
        radius: 24,
        x: 0,
        y: 8
    )
    /// Drag-and-drop, tooltips — maximum lift.
    public static let floating = ShadowToken(
        color: Ayu.accent.opacity(0.22),
        radius: 32,
        x: 0,
        y: 12
    )
    /// Pressed/inset button state — inner shadow via negative Y offset trick.
    public static let inner = ShadowToken(
        color: Ayu.accent.opacity(0.15),
        radius: 4,
        x: 0,
        y: -2
    )
}

/// A shadow definition for use with `.ayuShadow(_ token:)`.
public struct ShadowToken: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
}
```

### Pattern 2: Motion Token Enum

**What:** Duration and easing constants in a caseless enum; a guard pattern checks `@Environment(\.accessibilityReduceMotion)` at call site to return `.default` (instant) when reduce motion is on.

**When to use:** Every `.animation()` or `withAnimation {}` call in the codebase references `Motion.*` instead of raw literals.

**Example:**
```swift
public enum Motion {
    // MARK: - Durations
    /// 200ms — immediate feedback (hover, press).
    public static let durationFast: Double = 0.2
    /// 300ms — standard transitions (content swap, panel slide).
    public static let durationNormal: Double = 0.3
    /// 400ms — emphasized transitions (modal appear, loading complete).
    public static let durationEmphasis: Double = 0.4

    // MARK: - Curves
    /// easeInOut — symmetrical entry and exit, use for most transitions.
    public static let curveDefault: Animation = .easeInOut(duration: durationNormal)
    /// easeOut — fast start, graceful stop, use for elements appearing.
    public static let curveAppear: Animation = .easeOut(duration: durationNormal)
    /// easeInOut fast — hover/press feedback.
    public static let curveFast: Animation = .easeInOut(duration: durationFast)
    /// easeInOut emphasis — modal/sheet entrance.
    public static let curveEmphasis: Animation = .easeInOut(duration: durationEmphasis)
}

// View extension for reduce-motion guard
extension View {
    /// Applies an animation that respects macOS "Reduce Motion" accessibility setting.
    ///
    /// When reduce motion is enabled, uses `.default` (instant) instead of the provided animation.
    public func motionAnimation<V: Equatable>(
        _ animation: Animation,
        value: V,
        reduceMotion: Bool
    ) -> some View {
        self.animation(reduceMotion ? .default : animation, value: value)
    }
}
```

### Pattern 3: View Extension for Shadow Application

**What:** A `.ayuShadow(_ token:)` View extension that applies a `ShadowToken` — downstream components use tokens, not raw values.

**When to use:** All card, popover, modal, and floating element shadows use this instead of `.shadow(color:radius:x:y:)` directly.

**Example:**
```swift
extension View {
    /// Applies an Ayu elevation shadow from the design token system.
    public func ayuShadow(_ token: ShadowToken) -> some View {
        self.shadow(
            color: token.color,
            radius: token.radius,
            x: token.x,
            y: token.y
        )
    }
}
```

### Pattern 4: Window Size Enforcement

**What:** SwiftUI's `WindowGroup` on macOS 15 supports `.defaultSize(width:height:)` for first-launch dimensions and `.frame(minWidth:minHeight:)` on the root view enforces the minimum. There is no `windowResizability` needed — the min frame constraint is sufficient.

**When to use:** The 900pt minimum is enforced at the ContentView level; the 1280x800 default is set on the WindowGroup.

**Example:**
```swift
// In GenreUpdaterApp.swift
WindowGroup {
    ContentView()
        // ...
}
.defaultSize(width: 1280, height: 800)  // First-launch default

// In ContentView body
.frame(minWidth: 900, minHeight: 600)   // Change from 800 to 900
```

**Note:** `.defaultSize()` is available on macOS 13+. The project targets macOS 15 so no availability guard needed.

### Anti-Patterns to Avoid

- **Hardcoded shadow values in view files:** Use `Shadow.subtle` not `.shadow(color: .black.opacity(0.08), radius: 8)` — tokens exist to be the single source of truth.
- **Spring animations for non-special motion:** The locked decision is Bezier curves only. `GaugeView.swift` currently uses `.spring()` — this is exempted as a gauge-specific special case but should NOT be used for general transitions.
- **Raw `.animation()` literals in new code:** Always reference `Motion.curveDefault` etc. Raw `0.2` / `0.3` durations are banned in new view code once Motion tokens exist.
- **Ignoring reduce motion in new animation sites:** Every new `.animation()` call must check `@Environment(\.accessibilityReduceMotion)`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Inner shadows on macOS | Custom CALayer shadow hack or NSViewRepresentable | `.shadow()` with negative y offset (see Code Examples) | SwiftUI `.shadow()` with small radius + negative y is sufficient for a pressed/inset feel without AppKit interop |
| Color contrast verification | Manual eyeballing | Python/WCAG formula (already computed in research) | Exact computed values documented below — no guesswork needed |
| Reduce-motion detection | Polling NSWorkspace | `@Environment(\.accessibilityReduceMotion)` | Reactive SwiftUI Environment updates when user changes setting without restart |
| Window default size persistence | Manual UserDefaults | `.defaultSize()` on WindowGroup | SwiftUI manages first-launch geometry; subsequent sizes are auto-persisted by the system |

**Key insight:** SwiftUI's token layer is pure Swift value types. There is no runtime framework needed — enums + structs + view extensions are zero-dependency.

## Common Pitfalls

### Pitfall 1: Assuming fgPrimary Needs Fixing

**What goes wrong:** Developer darkens fgPrimary (#5C6166) based on STATE.md blocker note, making body text appear darker than Ayu intended.

**Why it happens:** STATE.md said "~4.2:1, just below WCAG AA" but the actual computed value is **6.10:1 on bgPrimary (#FCFCFC)** — well above the 4.5:1 threshold. The note was incorrect.

**How to avoid:** Only fix fgSecondary. Leave fgPrimary at #5C6166. Verified calculations below.

**Warning signs:** If the plan instructs changing fgPrimary hex — stop and re-verify with the contrast formula.

### Pitfall 2: fgSecondary Not Passing on bgSecondary (Cards)

**What goes wrong:** Darkening fgSecondary just enough to pass 4.5:1 on bgPrimary (#FCFCFC) but failing on bgSecondary (#F3F4F5) which is used for card and sidebar backgrounds.

**Why it happens:** bgSecondary is slightly darker than bgPrimary (luminance 0.922 vs 0.960), so it needs a slightly darker foreground to maintain 4.5:1.

**How to avoid:** Use `#697078` — verified at 4.89:1 on bgPrimary AND 4.55:1 on bgSecondary. This is the minimum fix that passes on both common backgrounds.

**Warning signs:** Any candidate lighter than #697078 (e.g. #6E757D = 4.23:1 on bgSecondary) fails the secondary background check.

### Pitfall 3: ShadowToken Color References Ayu.accent at Definition Time

**What goes wrong:** `ShadowToken` static lets reference `Ayu.accent` directly in their `color` property. Since `Ayu.accent` is a `Color.adaptive()` (resolved at render time), this is safe — but if the shadow is rendered outside a valid colorScheme context, the color may not adapt correctly.

**Why it happens:** Static property evaluation order in Swift — the Color.adaptive() closure captures NSColor appearance at creation, not at render time.

**How to avoid:** Verify that `ShadowToken` colors use the same `Color.adaptive()` mechanism that `AyuColors.swift` uses. Since `Ayu.accent` is already `Color.adaptive()`, referencing it in ShadowToken is safe — Color.adaptive() defers NSColor resolution to render time.

### Pitfall 4: Motion.curveDefault as Static let (Animation Is Not Sendable)

**What goes wrong:** Declaring `public static let curveDefault: Animation = .easeInOut(duration: ...)` may trigger Swift 6 Sendable warnings if `Animation` is not `Sendable`.

**Why it happens:** Swift 6 strict concurrency enforces `Sendable` on static properties of public types accessed from multiple concurrency domains.

**How to avoid:** Use `public static var` (computed) instead of `static let` for `Animation` values, OR check if `Animation` conforms to `Sendable` in macOS 15 SDK. If `Animation` IS Sendable, `static let` is fine. If not, use computed `static var` to avoid the conformance requirement.

**Verified status (HIGH confidence):** `SwiftUI.Animation` conforms to `Sendable` as of Swift 5.9+ (SE-0302). Using `static let` is safe.

### Pitfall 5: `.defaultSize()` vs `.frame()` Precedence

**What goes wrong:** Setting `.defaultSize(width: 1280, height: 800)` on WindowGroup but ContentView's `.frame(minWidth: 900, minHeight: 600)` still allows the window to be made smaller after first launch.

**Why it happens:** These are two separate constraints. `.defaultSize()` sets only the first-launch size. `.frame(minWidth:)` on the root view is what prevents resizing below 900pt at all times.

**How to avoid:** Both must be set. Update `ContentView`'s existing `.frame(minWidth: 800, minHeight: 600)` to `minWidth: 900`. Add `.defaultSize(width: 1280, height: 800)` to the WindowGroup.

### Pitfall 6: Forgetting `public` on ShadowToken

**What goes wrong:** `ShadowToken` is used in App target which imports SharedUI — it must be `public`. Forgetting this causes "cannot find type ShadowToken in scope" at compile time.

**Why it happens:** SPM enforces access control at package boundaries — SharedUI types used in App must be `public` per CLAUDE.md.

**How to avoid:** Add `public` to `ShadowToken` struct and all its properties.

## Code Examples

Verified patterns from SwiftUI documentation and existing project conventions:

### Shadow Application with Token

```swift
// Source: SwiftUI .shadow() modifier — official Apple API
// Pattern: matches existing applyLiquidGlass extension in DesignTokens.swift

extension View {
    public func ayuShadow(_ token: ShadowToken) -> some View {
        shadow(
            color: token.color,
            radius: token.radius,
            x: token.x,
            y: token.y
        )
    }
}

// Usage at call site:
MetricCard()
    .ayuShadow(Shadow.subtle)
```

### Reduce Motion Pattern (SwiftUI Environment)

```swift
// Source: SwiftUI @Environment — official Apple API
// This is the idiomatic SwiftUI way to respect system accessibility settings

struct SomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(reduceMotion ? .default : Motion.curveDefault, value: someValue)
    }
}
```

### Motion Token Enum

```swift
// Pattern: matches existing Spacing/Radius/AppFont in DesignTokens.swift
public enum Motion {
    public static let durationFast: Double = 0.2
    public static let durationNormal: Double = 0.3
    public static let durationEmphasis: Double = 0.4

    public static let curveFast: Animation = .easeInOut(duration: durationFast)
    public static let curveDefault: Animation = .easeInOut(duration: durationNormal)
    public static let curveAppear: Animation = .easeOut(duration: durationNormal)
    public static let curveEmphasis: Animation = .easeInOut(duration: durationEmphasis)
}
```

### Window Default Size (macOS 13+)

```swift
// Source: SwiftUI Scene modifiers — official Apple API
// .defaultSize is available from macOS 13; project targets macOS 15 so no guard needed

WindowGroup {
    ContentView()
        .environment(dependencies)
        // ...
}
.defaultSize(width: 1280, height: 800)
```

### Color Fix (AyuColors.swift)

```swift
// BEFORE
public static let fgSecondary = Color.adaptive(
    light: hex(0x8A9199),  // 3.11:1 on bgPrimary — FAILS WCAG AA
    dark: hex(0x8A9199)
)

// AFTER — minimal darkening to pass AA on all Ayu light surfaces
public static let fgSecondary = Color.adaptive(
    light: hex(0x697078),  // 4.89:1 on bgPrimary, 4.55:1 on bgSecondary — PASSES
    dark: hex(0x8A9199)    // Dark mode unchanged
)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hardcoded `.shadow(color:radius:x:y:)` in views | Token-based `Shadow` enum + `.ayuShadow()` extension | This phase | Single source of truth; changes propagate everywhere |
| Literal `0.2` / `0.3` in `.animation()` calls | `Motion.curveFast` / `Motion.curveDefault` | This phase | Consistency + reduce-motion support |
| `minWidth: 800` in ContentView | `minWidth: 900` + `.defaultSize(1280, 800)` on WindowGroup | This phase | Prevents layout collapse at browse/sidebar widths |

**Deprecated/outdated:**
- `Animation.spring()` for general transitions: Locked out by user decision; only retained in `GaugeView.swift` for the hero gauge animation which is explicitly spring-based.

## Open Questions

1. **`Spacing.row` vs component-level row height**
   - What we know: User wants 40-44pt row height across artist rows, track rows, and report log entries
   - What's unclear: Should this be a `Spacing.row: CGFloat = 44` constant, or handled per-component in Phase 6?
   - Recommendation: Add `Spacing.row: CGFloat = 44` to `DesignTokens.swift` now — it is a global design decision that belongs in the token layer and costs nothing to add alongside the other tokens in Phase 1.

2. **Inner shadow implementation on macOS**
   - What we know: SwiftUI's `.shadow()` produces drop shadows only. True inner shadows require either: (a) `.shadow()` + clip + negative offset trick, or (b) custom Shape drawing with reversed clipping
   - What's unclear: Whether the "inner shadow for pressed state" needs true inner rendering or whether a subtle dark border/overlay effect is sufficient
   - Recommendation: Use the simplified approach — a very small `.shadow(y: -1, radius: 2)` with clip applied. If the visual result is insufficient, escalate to a custom Shape in Phase 3 (interactive states).

3. **GaugeView spring animation exemption**
   - What we know: `GaugeView.swift` uses `.spring(duration: 1.0, bounce: 0.3)` which contradicts the locked "Bezier only" motion decision
   - What's unclear: Whether this exemption is intentional or should be migrated to Motion tokens
   - Recommendation: Treat GaugeView spring as an explicit exemption — the gauge entrance is a special one-time animation, not a general UI transition. Document in a `// Exemption: gauge entrance uses spring` comment. Do NOT convert it to `Motion.curveEmphasis`.

## Contrast Audit Results

Full computed WCAG contrast ratios (all on Ayu light surfaces, WCAG AA threshold = 4.5:1):

| Color | Hex | bgPrimary (#FCFCFC) | bgSecondary (#F3F4F5) | bgTertiary (#E8E9EB) | Status |
|-------|-----|---------------------|----------------------|---------------------|--------|
| fgPrimary | #5C6166 | 6.10:1 | 5.68:1 | 5.15:1 | PASS (no change needed) |
| fgSecondary (current) | #8A9199 | 3.11:1 | 2.89:1 | 2.62:1 | FAIL |
| fgSecondary (fixed) | #697078 | 4.89:1 | 4.55:1 | — | PASS |
| fgMuted | #787B80 | 4.14:1 | — | — | Exempt (disabled UI) |
| accent | #FFAA33 | — | — | — | Not applicable (background use only) |

**fgMuted exemption:** WCAG 1.4.3 explicitly exempts "inactive user interface components" from contrast requirements. fgMuted is used for disabled and muted text — no change required.

## Sources

### Primary (HIGH confidence)
- SwiftUI `.shadow()` modifier — Apple developer documentation
- SwiftUI `@Environment(\.accessibilityReduceMotion)` — Apple developer documentation
- SwiftUI Scene `.defaultSize()` — Apple developer documentation (macOS 13+)
- WCAG 2.1 Success Criterion 1.4.3 — Contrast (Minimum) — w3.org/TR/WCAG21
- WCAG relative luminance formula — implemented and verified in research script

### Secondary (MEDIUM confidence)
- `Animation` Sendable conformance (SE-0302, Swift 5.9+) — verified through known Swift Evolution proposals

### Project-Verified (HIGH confidence)
- AyuColors.swift — `Color.adaptive()` pattern, all current hex values verified by direct file read
- DesignTokens.swift — existing Spacing/Radius/AppFont enum pattern verified by direct file read
- GenreUpdaterApp.swift — current `minWidth: 800` and Settings `.frame(minWidth: 520)` verified by direct file read
- SharedUI/Package.swift — confirmed no new dependencies needed; existing SwiftUI/AppKit sufficient

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no external dependencies; existing Apple frameworks verified in project
- Architecture: HIGH — exact enum pattern copied from existing project files
- Color values: HIGH — mathematically computed with WCAG formula, not estimated
- Pitfalls: HIGH — most derive from direct code inspection of current project state
- Window sizing API: HIGH — `.defaultSize()` is stable macOS 13+ API

**Research date:** 2026-02-22
**Valid until:** 2026-08-22 (6 months — stable Apple APIs, no moving parts)
