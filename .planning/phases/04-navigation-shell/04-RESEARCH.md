# Phase 4: Navigation Shell - Research

**Researched:** 2026-02-22
**Domain:** SwiftUI NavigationSplitView custom sidebar, matchedGeometryEffect, Lucide icon integration, column layout control (macOS)
**Confidence:** HIGH

## Summary

Phase 4 transforms the existing prototype sidebar (`List` with `.sidebar` style) into a polished, branded navigation shell with Ayu-themed backgrounds, animated active indicators, and correct column behavior per screen. The current `MainView.swift` uses a three-column `NavigationSplitView` with `columnVisibility` toggling between `.all` and `.doubleColumn` -- this core structure stays, but the sidebar content gets completely replaced with a custom view, and Lucide icons replace SF Symbols for sidebar items.

The three main technical domains are: (1) custom sidebar with Ayu background and `matchedGeometryEffect` sliding pill, (2) Lucide icon integration via the `lucide-icons-swift` SPM package, and (3) column visibility control ensuring Dashboard/Update/Reports never show a detail panel. All three are well-supported by existing SwiftUI APIs on macOS 15+ and the project's existing architecture.

**Primary recommendation:** Replace the sidebar `List` with a custom `VStack` in `ScrollView` using `.scrollContentBackground(.hidden)` + Ayu background, implement the sliding pill with `matchedGeometryEffect` using `@Namespace`, and add `lucide-icons-swift` 0.575.0 to SharedUI's Package.swift.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Sidebar Look & Feel:**
- Adaptive background: light in light mode, dark in dark mode (NOT always-dark). Uses `Ayu.bgPrimary` / `Ayu.bgSecondary` depending on mode
- Both compact/expanded modes supported, switchable via toggle button at top of sidebar
- Toggle icon: `sidebar.left` SF Symbol
- Persisted via `@AppStorage` across launches
- Expanded: icon + text label; Compact: icons only with tooltip on hover
- Compact background: transparent (not tinted)
- Compact section headers: replaced with thin divider line (no text)
- Expanded width: 160--260pt, resizable via `navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)`
- Compact <-> expanded transition: smooth width resize with text fade in/out
- Two sections: LIBRARY (Dashboard, Browse, Reports) / TOOLS (Update)
- Headers: uppercase, small font, `Ayu.fgSecondary`
- SF Symbols: outlined style (not filled) -- lighter, minimalist
- Footer: Settings gear icon at bottom, visible in both modes, opens system Settings window
- Hover: non-active items show subtle bgTertiary background on hover, animated with `Motion.curveFast`
- No branding/logo at top

**Active Item Highlight:**
- Pill background (rounded rectangle) like Apple Music sidebar
- Fill: `Ayu.accent.opacity(0.15)`
- Border: 1pt `Ayu.accent` stroke
- Active text/icon color: `Ayu.accent`
- Font weight unchanged (no bold on active)
- Compact mode: pill around icon (circle or rounded square)
- Animation: `matchedGeometryEffect` with `Motion.curveSmooth` (~0.35s)

**Column Layout:**
- Dashboard, Update, Reports: two-column (sidebar + content, NO detail panel)
- Browse: three-column when track selected; two-column when no track selected
- Browse empty detail: hide detail column with animation (`.doubleColumn`). Deferred to Phase 5/6: ambient HeroGauge visualization
- Track selection persistence: preserve selection when navigating away from Browse
- Content/Detail proportions (Browse): default 40:60, native resize, min content width 320pt
- Narrow window: detail auto-collapses at minimum (~900pt) with Browse + detail open
- Non-Browse content: centered with max-width (~800pt) + consistent padding
- Content transition: cross-fade (`.contentTransition(.opacity)`) -- already implemented

**Sidebar Items & Ordering:**
- LIBRARY section: Dashboard (Cmd+1), Browse (Cmd+2), Reports (Cmd+3)
- TOOLS section: Update (Cmd+4)
- Footer: Settings gear
- Lucide icons (ISC license) for all sidebar navigation items -- specific icons selected during planning
- Badges: off by default, toggle option persisted via `@AppStorage`
- Keyboard: Cmd+1-4 follows visual order

### Claude's Discretion
- Specific Lucide icon selection for each sidebar item (research Lucide set)
- Implementation details for compact/expanded toggle animation
- How to structure the sidebar component (SharedUI vs App target)

### Deferred Ideas (OUT OF SCOPE)
1. Ambient HeroGauge in Browse empty detail -- requires HeroGauge + real data (Phase 5/6)
2. Custom icon design -- if Lucide doesn't match, separate design task
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| NAV-01 | Sidebar has Ayu dark background with matchedGeometryEffect sliding active indicator | Custom sidebar with `.scrollContentBackground(.hidden)` + Ayu background + `@Namespace` matchedGeometryEffect pill pattern -- verified working on macOS 15+ |
| NAV-02 | Dashboard, Update, and Reports screens use doubleColumn layout (no spurious "Select a Track" panel) | Existing `updateColumnVisibility()` pattern in MainView already sets `.doubleColumn` -- needs refinement to prevent detail from rendering at all for non-Browse screens |
| NAV-03 | App enforces minimum window width of 900pt to prevent layout collapse | Already implemented in Phase 1 via `.frame(minWidth: 900, minHeight: 600)` on ContentView -- validate it works with the new sidebar layout |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI NavigationSplitView | macOS 15+ | Three-column layout with sidebar/content/detail | Apple's built-in split navigation; already in use in MainView |
| SwiftUI matchedGeometryEffect | macOS 13+ | Sliding pill animation between sidebar items | Apple's standard API for synchronized geometry animations |
| LucideIcons | 0.575.0 | Sidebar navigation icons (ISC license) | Community-standard icon set; only SPM package for Lucide on Swift |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| @AppStorage | Built-in | Persist sidebar compact/expanded state, badge toggle | User preferences that survive app restarts |
| @Namespace | Built-in | Namespace for matchedGeometryEffect pill | Required for matched geometry coordination |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| LucideIcons SPM | SVG assets in asset catalog | Manual management, no auto-updates, but zero dependency |
| Custom VStack sidebar | List with .scrollContentBackground(.hidden) | List gives built-in selection behavior but less control over custom styling |
| matchedGeometryEffect | .offset + .animation | matchedGeometryEffect handles size+position automatically; manual offset is fragile |

**Installation:**

Add to `Packages/SharedUI/Package.swift`:
```swift
.package(url: "https://github.com/JakubMazur/lucide-icons-swift.git", from: "0.575.0"),
```

And add to the SharedUI target dependencies:
```swift
.product(name: "LucideIcons", package: "lucide-icons-swift"),
```

Also add to `project.yml` packages section:
```yaml
LucideIcons:
  url: https://github.com/JakubMazur/lucide-icons-swift.git
  from: 0.575.0
```

**Note:** LucideIcons depends on SharedUI (for sidebar components), NOT on App directly. The App target already depends on SharedUI transitively.

## Architecture Patterns

### Recommended File Structure
```
App/
├── Views/
│   └── MainView.swift              # Refactored: custom sidebar, column routing
Packages/SharedUI/Sources/SharedUI/
├── Components/
│   ├── SidebarView.swift            # NEW: Full sidebar component
│   ├── SidebarItemView.swift        # NEW: Individual sidebar row with matched geometry
│   └── SidebarSectionHeader.swift   # NEW: Section header (expanded) / divider (compact)
├── Theme/
│   └── DesignTokens.swift           # ADD: Motion.curveSmooth (0.35s) if not present
```

### Pattern 1: matchedGeometryEffect Sliding Pill

**What:** The active sidebar item has a pill-shaped background that slides between items using `matchedGeometryEffect`.

**When to use:** When you need a smooth position+size animation between discrete UI elements that share a visual indicator.

**Example:**
```swift
// Source: https://nilcoalescing.com/blog/CustomSegmentedControlWithMatchedGeometryEffect/
// Verified against Apple docs: https://developer.apple.com/documentation/SwiftUI/View/matchedGeometryEffect(id:in:properties:anchor:isSource:)

struct SidebarView: View {
    @Binding var selectedCategory: NavigationCategory?
    @Namespace private var sidebarNamespace

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            ForEach(NavigationCategory.allInOrder) { category in
                SidebarItemView(
                    category: category,
                    isSelected: selectedCategory == category,
                    namespace: sidebarNamespace
                ) {
                    withAnimation(Motion.curveSmooth) {
                        selectedCategory = category
                    }
                }
            }
        }
    }
}

struct SidebarItemView: View {
    let category: NavigationCategory
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(category.rawValue, image: category.lucideIconName)
                .foregroundStyle(isSelected ? Ayu.accent : Ayu.fgPrimary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Ayu.accent.opacity(0.15))
                    .strokeBorder(Ayu.accent, lineWidth: 1)
                    .matchedGeometryEffect(id: "activeIndicator", in: namespace)
            }
        }
    }
}
```

**Key detail:** The pill background uses `matchedGeometryEffect` with a fixed ID (`"activeIndicator"`) and `isSource` defaults to `true`. Because only the selected item renders the pill, SwiftUI automatically animates position and size between whichever item was previously selected and the newly selected one. The `withAnimation(Motion.curveSmooth)` wrapping the state change drives the animation timing.

### Pattern 2: Custom Sidebar with Ayu Background

**What:** Replace the default `List(.sidebar)` with a custom `ScrollView` + `VStack` to get full control over background color, item styling, and section headers.

**When to use:** When the default sidebar List styling doesn't match the design (custom background, custom selection indicator, custom hover).

**Example:**
```swift
// Sidebar column in NavigationSplitView
NavigationSplitView(columnVisibility: $columnVisibility) {
    // Custom sidebar -- NOT a List
    VStack(spacing: 0) {
        // Toggle button at top
        sidebarToggle

        ScrollView {
            VStack(spacing: Spacing.xxs) {
                SidebarSectionHeader(title: "LIBRARY", isCompact: isCompact)
                // Dashboard, Browse, Reports items

                SidebarSectionHeader(title: "TOOLS", isCompact: isCompact)
                // Update item
            }
            .padding(.horizontal, Spacing.xs)
        }

        Spacer()

        // Settings footer
        settingsButton
    }
    .background(isCompact ? Color.clear : Ayu.bgSecondary)
    .navigationSplitViewColumnWidth(min: isCompact ? 52 : 160, ideal: isCompact ? 52 : 200, max: isCompact ? 52 : 260)
} content: {
    contentView
} detail: {
    detailView
}
```

### Pattern 3: Column Visibility Control

**What:** Dynamically show/hide the detail column based on which screen is active and whether a track is selected.

**When to use:** Dashboard, Update, and Reports should NEVER show a detail panel. Browse shows detail only when a track is selected.

**Example:**
```swift
// Existing pattern in MainView -- refine to be more explicit
private func updateColumnVisibility() {
    let needsDetail = selectedCategory == .browse && selectedTrack != nil
    let target: NavigationSplitViewVisibility = needsDetail ? .all : .doubleColumn
    if columnVisibility != target {
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = target
        }
    }
}

// Detail column -- render empty for non-Browse to avoid "Select a Track"
@ViewBuilder
private var trackDetail: some View {
    if selectedCategory == .browse {
        if let track = selectedTrack {
            TrackDetailView(track: track)
        } else {
            // Empty -- column is hidden via .doubleColumn anyway
            Color.clear
        }
    } else {
        // Non-Browse screens: no detail at all
        Color.clear
    }
}
```

### Pattern 4: Compact/Expanded Toggle with Animated Transition

**What:** Sidebar supports both expanded (icon + text) and compact (icon only) modes with smooth transition.

**Example:**
```swift
@AppStorage("sidebarCompact") private var isCompact = false

// Toggle button
Button {
    withAnimation(Motion.curveDefault) {
        isCompact.toggle()
    }
} label: {
    Image(systemName: "sidebar.left")
        .foregroundStyle(Ayu.fgSecondary)
}
.buttonStyle(.plain)

// In sidebar items, conditionally show text
HStack(spacing: Spacing.sm) {
    Image(nsImage: category.lucideIcon)
        .resizable()
        .frame(width: 18, height: 18)

    if !isCompact {
        Text(category.rawValue)
            .font(AppFont.body)
            .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}
.frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
```

### Pattern 5: Lucide Icon Integration (macOS)

**What:** Access Lucide icons as `NSImage` and wrap in SwiftUI `Image`.

**Example:**
```swift
import LucideIcons

// Access icon as NSImage
let icon: NSImage = Lucide.layoutDashboard  // camelCase property name

// Use in SwiftUI
Image(nsImage: Lucide.layoutDashboard)
    .resizable()
    .frame(width: 18, height: 18)
    .foregroundStyle(isSelected ? Ayu.accent : Ayu.fgPrimary)
```

**Icon name mapping (Lucide kebab-case -> Swift camelCase):**
- `layout-dashboard` -> `Lucide.layoutDashboard`
- `music-2` -> `Lucide.music2`
- `chart-bar` -> `Lucide.chartBar`
- `wand-sparkles` -> `Lucide.wandSparkles`

### Anti-Patterns to Avoid

- **Using `List` with heavy style overrides:** Don't try to customize `List(.sidebar)` with `.scrollContentBackground(.hidden)` + custom backgrounds. It's brittle -- selection states, row backgrounds, and section headers all fight the custom styling. Use a custom `VStack` in `ScrollView` instead for full control.
- **Conditional NavigationSplitView (2-col vs 3-col):** Don't switch between `init(sidebar:detail:)` and `init(sidebar:content:detail:)` based on selection. This causes view identity issues and animation glitches. Use one three-column `init(sidebar:content:detail:)` consistently and control visibility via `columnVisibility`.
- **Hardcoding matchedGeometryEffect IDs per item:** The pill should have ONE ID ("activeIndicator") that only appears on the selected item. Don't give each item its own geometry ID -- that defeats the purpose (there's nothing to animate between).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sliding active indicator | Manual `.offset()` + `.animation()` tracking | `matchedGeometryEffect` | Automatically handles position AND size interpolation; manual approach breaks on window resize |
| Icon set for sidebar | Custom SVG assets + manual catalog | `lucide-icons-swift` SPM package | Auto-updated, 1500+ icons, ISC license, handles platform differences |
| Column visibility management | Custom `if/else` switching NavigationSplitView type | `NavigationSplitViewVisibility` binding | Apple's API handles column width animation and memory management |
| Hover state detection | NSTrackingArea via Introspect | `.onHover { }` modifier | Built into SwiftUI macOS 13+; no AppKit bridge needed |

**Key insight:** macOS 15+ SwiftUI has everything needed for this phase natively -- no AppKit introspection, no third-party UI libraries. The only external dependency is `lucide-icons-swift` for the icons themselves.

## Common Pitfalls

### Pitfall 1: matchedGeometryEffect Namespace Scope
**What goes wrong:** The `@Namespace` is declared in a child view that gets recreated, causing the animation to jump instead of slide.
**Why it happens:** When the view owning `@Namespace` is recreated, the namespace identity changes and SwiftUI can't match the old geometry to the new.
**How to avoid:** Declare `@Namespace` in the sidebar container view that persists across selection changes, NOT in individual item views. Pass the `namespace: Namespace.ID` down to child views.
**Warning signs:** The pill teleports instead of sliding; works on first tap but not subsequent ones.

### Pitfall 2: NavigationSplitView Detail Still Renders
**What goes wrong:** Even with `columnVisibility = .doubleColumn`, the detail view's body still executes, and on macOS the detail column may flash briefly.
**Why it happens:** SwiftUI renders all columns' body closures regardless of visibility -- `.doubleColumn` hides the column visually but doesn't prevent rendering.
**How to avoid:** Guard the detail content with a check: only render `TrackDetailView` when `selectedCategory == .browse && selectedTrack != nil`. Otherwise return `Color.clear` or `EmptyView()`.
**Warning signs:** "Select a Track" placeholder appearing momentarily during screen transitions.

### Pitfall 3: Compact Sidebar Width Animation
**What goes wrong:** The sidebar snaps to the new width instead of animating smoothly when toggling compact/expanded.
**Why it happens:** `navigationSplitViewColumnWidth` doesn't animate by default -- it sets a constraint, not an animatable property.
**How to avoid:** Wrap the `isCompact` toggle in `withAnimation(Motion.curveDefault)`. The width change should be driven by the content size change (text appearing/disappearing) rather than changing the column width constraint directly. Alternatively, use a fixed wider width and let the content center itself in compact mode.
**Warning signs:** Jarring snap when toggling; content overlapping during transition.

### Pitfall 4: Lucide Icon Rendering Color
**What goes wrong:** Lucide icons render as black/original color and don't respond to `.foregroundStyle()`.
**Why it happens:** NSImage-based icons may be rendered as template images or not. The `lucide-icons-swift` package delivers icons as bundled assets which may not be configured as template images.
**How to avoid:** After getting the NSImage, set `.isTemplate = true` before wrapping in SwiftUI Image, OR use `.renderingMode(.template)` on the SwiftUI Image. This allows `.foregroundStyle()` to tint the icon.
**Warning signs:** Icons stay black/white regardless of theme; accent color not applied to active item icon.

### Pitfall 5: Sidebar Toggle Conflicts with System Sidebar Toggle
**What goes wrong:** macOS adds a default sidebar toggle button in the toolbar. Having both the system toggle and a custom compact/expanded toggle creates confusing behavior.
**Why it happens:** `NavigationSplitView` automatically adds a `sidebarToggle` toolbar item.
**How to avoid:** Use `.toolbar(removing: .sidebarToggle)` to remove the system toggle if the custom toggle replaces it. Or keep the system toggle for hide/show and only use the custom toggle for compact/expanded mode (different behaviors).
**Warning signs:** Two toggle buttons; sidebar disappearing entirely when user clicks the wrong one.

### Pitfall 6: Content Area Max-Width Centering
**What goes wrong:** Dashboard/Update/Reports content stretches to fill the entire content area on wide windows, looking sparse.
**Why it happens:** By default, SwiftUI views expand to fill available space.
**How to avoid:** Wrap non-Browse content in a `.frame(maxWidth: 800)` centered container. Apply this consistently across Dashboard, Update, and Reports.
**Warning signs:** Content looks stretched on 27"+ displays; line lengths become uncomfortably long.

## Code Examples

### Lucide Icon Access (macOS, verified)
```swift
// Source: https://github.com/JakubMazur/lucide-icons-swift (README)
import LucideIcons

// Direct property access (camelCase)
let dashboardIcon: NSImage = Lucide.layoutDashboard
let browseIcon: NSImage = Lucide.music2
let reportsIcon: NSImage = Lucide.chartBar
let updateIcon: NSImage = Lucide.wandSparkles

// SwiftUI wrapper with template rendering for color tinting
func lucideImage(_ icon: NSImage, size: CGFloat = 18) -> some View {
    let templateIcon = icon.copy() as! NSImage
    templateIcon.isTemplate = true
    return Image(nsImage: templateIcon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
}
```

### Hover State on Sidebar Item
```swift
// Source: SwiftUI .onHover modifier (Apple docs, macOS 13+)
@State private var isHovered = false

SidebarItemContent(...)
    .background {
        if !isSelected && isHovered {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.bgTertiary)
        }
    }
    .onHover { hovering in
        withAnimation(Motion.curveFast) {
            isHovered = hovering
        }
    }
```

### Section Header (Expanded vs. Compact)
```swift
struct SidebarSectionHeader: View {
    let title: String
    let isCompact: Bool

    var body: some View {
        if isCompact {
            Divider()
                .padding(.vertical, Spacing.xs)
        } else {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ayu.fgSecondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxs)
        }
    }
}
```

### Content Area Max-Width Container
```swift
// Applied to Dashboard, Update, Reports content areas
struct ContentContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity) // Centers the constrained content
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.xxl)
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `.listStyle(.sidebar)` with default styling | Custom sidebar with full control | macOS 13+ (scrollContentBackground) | Full visual control without AppKit introspection |
| `NavigationView` | `NavigationSplitView` | macOS 13 / WWDC 2022 | Proper column visibility control |
| Custom `.offset()` animations | `matchedGeometryEffect` | macOS 13 / SwiftUI 4 | Declarative geometry synchronization |
| SF Symbols only | Lucide via SPM + SF Symbols for UI chrome | 2024+ | Distinct visual identity, modern analytical feel |
| `ObservableObject` | `@Observable` | macOS 14 / WWDC 2023 | Simpler, no `@Published`, better performance |

**Deprecated/outdated:**
- `NavigationView`: Replaced by `NavigationSplitView` + `NavigationStack`. Still compiles but deprecated.
- `.accentColor()`: Deprecated in favor of `.tint()` and asset catalog accent color.

## Lucide Icon Recommendations

Based on the Lucide icon library (1,557 icons, ISC license), the following icons match the sidebar items' semantic meaning and maintain visual consistency:

| Sidebar Item | Lucide Icon | Swift Property | Rationale |
|-------------|-------------|----------------|-----------|
| Dashboard | `layout-dashboard` | `Lucide.layoutDashboard` | Directly maps to "dashboard overview" concept; 4-panel grid icon |
| Browse | `music-2` | `Lucide.music2` | Music note (quaver); matches Music.app browsing |
| Reports | `chart-bar` | `Lucide.chartBar` | Bar chart; directly maps to reports/analytics |
| Update | `wand-sparkles` | `Lucide.wandSparkles` | Magic wand; matches "auto-update" / "fix" metaphor |

**Alternative options if the above don't feel right:**
- Dashboard: `gauge` (speedometer), `activity` (pulse line)
- Browse: `library` (book stack), `disc-3` (vinyl)
- Reports: `chart-line`, `trending-up`, `bar-chart-2`
- Update: `sparkles`, `refresh-cw`, `zap`

**Settings footer** keeps the SF Symbol `gear` (`gearshape`) since it's UI chrome, not app content -- consistent with the CONTEXT.md distinction.

## Open Questions

1. **Lucide icon template rendering**
   - What we know: `lucide-icons-swift` delivers NSImage from xcassets bundle; `.isTemplate` may or may not be set
   - What's unclear: Whether icons are pre-configured as template images or need manual `isTemplate = true`
   - Recommendation: Test at implementation time. Create a helper that always sets `isTemplate = true` to ensure `.foregroundStyle()` works. LOW risk -- easy to fix.

2. **Motion.curveSmooth token**
   - What we know: CONTEXT.md specifies `Motion.curveSmooth` (~0.35s) for the pill animation. Current DesignTokens.swift has `curveDefault` (0.3s), `curveFast` (0.2s), `curveEmphasis` (0.4s) -- no `curveSmooth`
   - What's unclear: Whether to add a new token or reuse existing
   - Recommendation: Add `Motion.curveSmooth` as `.easeInOut(duration: 0.35)` -- it's distinct from existing tokens and explicitly requested

3. **Compact sidebar column width**
   - What we know: Expanded width is 160-260pt. Compact mode needs narrower width (~52pt for icon-only)
   - What's unclear: Whether `navigationSplitViewColumnWidth` animates smoothly when min/ideal/max change between compact/expanded
   - Recommendation: Use a single wider `navigationSplitViewColumnWidth` and let compact content center within it, OR test dynamic width change. May need conditional width modifier.

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation: NavigationSplitView (`init(columnVisibility:sidebar:content:detail:)`) -- column visibility API verified
- Apple Developer Documentation: matchedGeometryEffect -- API signature and behavior verified via Context7
- Apple Developer Documentation: NavigationSplitViewVisibility (`.doubleColumn`, `.all`) -- confirmed for three-column split views
- [lucide-icons-swift GitHub](https://github.com/JakubMazur/lucide-icons-swift) -- v0.575.0 confirmed, macOS support verified, `NSImage.image(lucideId:)` API documented

### Secondary (MEDIUM confidence)
- [Nil Coalescing: Custom Segmented Control with matchedGeometryEffect](https://nilcoalescing.com/blog/CustomSegmentedControlWithMatchedGeometryEffect/) -- pill sliding pattern verified
- [Hacking with Swift: scrollContentBackground](https://www.hackingwithswift.com/quick-start/swiftui/how-to-change-the-background-color-of-list-texteditor-and-more) -- `.scrollContentBackground(.hidden)` on macOS 13+ confirmed
- [Lucide Icons Official](https://lucide.dev/icons/) -- icon names and categories verified

### Tertiary (LOW confidence)
- Lucide icon Swift property names (camelCase mapping) -- inferred from README examples (`Lucide.tada`), not exhaustively verified for all 4 recommended icons. Validate during implementation.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all APIs are Apple-native (macOS 15+) or well-maintained SPM packages with recent releases
- Architecture: HIGH -- patterns verified against Apple docs and existing codebase; matchedGeometryEffect is a well-documented standard pattern
- Pitfalls: HIGH -- each pitfall is based on documented SwiftUI behavior or direct codebase observation
- Lucide integration: MEDIUM -- SPM package exists and is maintained (0.575.0, Feb 2026), but Swift property names for specific icons need runtime validation

**Research date:** 2026-02-22
**Valid until:** 2026-03-22 (stable APIs, no fast-moving changes expected)
