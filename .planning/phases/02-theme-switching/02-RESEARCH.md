# Phase 2: Theme Switching - Research

**Researched:** 2026-02-22
**Domain:** SwiftUI appearance management, AppKit NSApp.appearance, @AppStorage persistence, macOS theme switching
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Picker placement**
- New **Appearance** tab in Settings (4th tab, after Advanced)
- Tab icon: `paintbrush` or similar SF Symbol
- Appearance tab also includes a placeholder section for sidebar style (populated in Phase 4)

**Picker style**
- Segmented picker with SF Symbol icons only -- no text labels
- Three segments: `moon.fill` (Dark) / `circle.lefthalf.filled` (System) / `sun.max.fill` (Light)
- Compact, recognizable without text

**Color preview**
- Small color swatch row beneath the picker showing bg + fg + accent colors for the selected theme
- Updates live as the user switches segments

**Default theme**
- System mode at first launch -- follows OS appearance out of the box

**System mode indicator**
- No explicit "currently using Dark/Light" label -- the user sees the app colors directly

**Transition behavior**
- Animated cross-fade (~0.3s) for all theme changes -- both manual switches in Settings and OS-driven changes
- Applies to all windows simultaneously (main window + Settings window)

**Scope of change**
- Theme switch applies to the entire app immediately -- sidebar, content area, Settings window, sheets, date pickers all change

### Claude's Discretion
- SF Symbol choices for tab icon and segment icons (exact names)
- Cross-fade animation implementation approach (preferredColorScheme + withAnimation, or NSAppearance transition)
- Color preview swatch layout and sizing
- Appearance tab layout for sidebar style placeholder section

### Deferred Ideas (OUT OF SCOPE)
- Sidebar style toggle -- deferred to Phase 4 (Navigation Shell); Appearance tab will have a placeholder section ready
- Menu bar / toolbar access to theme switching -- not in scope for this phase; could be added as a v2 enhancement
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DSYS-01 | User can switch between dark and light themes (auto-detect system preference with manual override via Settings) | Dual-layer approach: `preferredColorScheme(_:)` on WindowGroup content for SwiftUI views + `NSApp.appearance` for AppKit surfaces (sheets, date pickers); @AppStorage persists preference as String-backed enum; `nil` for System mode tracks OS in real time |
</phase_requirements>

## Summary

Theme switching on macOS SwiftUI requires a **dual-layer approach** because `preferredColorScheme(_:)` alone does not affect AppKit surfaces (date pickers, confirmation dialogs, and some sheet chrome). The proven pattern is: (1) apply `.preferredColorScheme()` on the root view of each Scene for SwiftUI rendering, and (2) set `NSApp.appearance` to `NSAppearance(named: .aqua)`, `.darkAqua`, or `nil` (system) for AppKit surface coverage.

The existing `AyuColors.swift` color system already uses `Color.adaptive(light:dark:)` which resolves colors via `NSColor` appearance callbacks. This means all Ayu colors will automatically respond to appearance changes -- no color system modifications are needed. The `ShadowToken` values that reference `Ayu.accent.opacity(...)` will also adapt correctly because the underlying `Color.adaptive()` defers resolution to render time.

The implementation is compact: one new enum (`AppearanceMode`), one `@AppStorage` property, one new Settings tab, and three modifier/property changes in the app entry point. The animation for theme transitions uses `withAnimation(Motion.curveDefault)` wrapping the state change, which causes SwiftUI to cross-fade all views that depend on the color scheme.

**Primary recommendation:** Create an `AppearanceMode` enum (String-backed for @AppStorage) in SharedUI, add an Appearance tab to SettingsView, and apply `preferredColorScheme` + `NSApp.appearance` in GenreUpdaterApp.swift driven by the stored preference.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI (Apple) | macOS 15 | `.preferredColorScheme(_:)`, `@Environment(\.colorScheme)`, `@AppStorage` | Already in project; primary framework for view-level appearance |
| AppKit (Apple) | macOS 15 | `NSApp.appearance`, `NSAppearance(named:)` | Required for AppKit surface coverage (date pickers, sheets); already implicitly available via macOS target |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| No additions needed | -- | Phase 2 is pure Swift/SwiftUI/AppKit | No external dependencies required |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `NSApp.appearance` for AppKit surfaces | `preferredColorScheme` only | `preferredColorScheme` alone does NOT affect AppKit-backed controls (DatePicker, confirmationDialog); dual approach is required |
| `@AppStorage` with String enum | `UserDefaults` direct + `@Published` | @AppStorage is both persistence AND view invalidation in one; UserDefaults requires manual observation boilerplate |
| `withAnimation` on state change | `NSAnimationContext.runAnimationGroup` | SwiftUI's `withAnimation` handles the cross-fade of all dependent views automatically; NSAnimationContext is for AppKit views only |

## Architecture Patterns

### Recommended Project Structure

Changes land in 3 existing files + potentially 1 new file:

```
Packages/SharedUI/Sources/SharedUI/
├── Theme/
│   ├── AppearanceMode.swift  <- NEW: enum + helper (or add to DesignTokens.swift)
│   ├── DesignTokens.swift    <- No changes needed
│   └── AyuColors.swift       <- No changes needed (adaptive colors already work)
App/
├── GenreUpdaterApp.swift     <- Add preferredColorScheme + NSApp.appearance
└── Views/
    └── SettingsView.swift    <- Add Appearance tab (4th tab)
```

### Pattern 1: AppearanceMode Enum (String-backed for @AppStorage)

**What:** A `RawRepresentable` enum with String raw values that maps to both `ColorScheme?` (for SwiftUI) and `NSAppearance?` (for AppKit). String-backed because `@AppStorage` natively supports String raw values.

**When to use:** The single source of truth for the user's theme preference.

**Example:**
```swift
// Source: SwiftUI @AppStorage + RawRepresentable pattern
// Place in SharedUI so both App and SharedUI can reference it

public enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// SwiftUI color scheme override. Returns nil for system (follow OS).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// SF Symbol for the segmented picker.
    public var symbolName: String {
        switch self {
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        }
    }

    /// Accessibility label for VoiceOver.
    public var accessibilityLabel: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
```

### Pattern 2: Dual-Layer Appearance Application

**What:** Both `preferredColorScheme` (SwiftUI) and `NSApp.appearance` (AppKit) are set simultaneously from the same source of truth. This ensures all surfaces -- SwiftUI views, AppKit sheets, date pickers, and system chrome -- honor the selected theme.

**When to use:** Every time the appearance mode changes (user selection or app launch).

**Example:**
```swift
// In GenreUpdaterApp.swift
@main
struct GenreUpdaterApp: App {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(appearanceMode.colorScheme)
                // ... existing modifiers
        }
        // ... existing modifiers

        Settings {
            SettingsView()
                .preferredColorScheme(appearanceMode.colorScheme)
                // ... existing modifiers
        }
    }
}
```

```swift
// NSApp.appearance must be set imperatively (not declarative)
// Use .onChange or .onAppear to sync
.onChange(of: appearanceMode) { _, newMode in
    withAnimation(Motion.curveDefault) {
        applyAppearance(newMode)
    }
}
.onAppear {
    applyAppearance(appearanceMode)
}

private func applyAppearance(_ mode: AppearanceMode) {
    switch mode {
    case .system:
        NSApp.appearance = nil  // Follow OS
    case .light:
        NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
```

### Pattern 3: Segmented Picker with SF Symbols Only

**What:** A `Picker` with `.pickerStyle(.segmented)` that uses `Label` views with SF Symbols. The `.labelStyle(.iconOnly)` modifier hides text labels, showing only icons.

**When to use:** The theme selector in the Appearance tab.

**Example:**
```swift
Picker("Appearance", selection: $appearanceMode) {
    ForEach(AppearanceMode.allCases, id: \.self) { mode in
        Image(systemName: mode.symbolName)
            .accessibilityLabel(mode.accessibilityLabel)
            .tag(mode)
    }
}
.pickerStyle(.segmented)
```

### Pattern 4: Color Preview Swatches

**What:** A row of small rounded rectangles showing the bg, fg, and accent colors for the currently resolved theme. Uses `@Environment(\.colorScheme)` to read the effective scheme and display corresponding Ayu colors.

**When to use:** Below the segmented picker in the Appearance tab.

**Example:**
```swift
HStack(spacing: Spacing.xs) {
    ColorSwatch(color: Ayu.bgPrimary, label: "Background")
    ColorSwatch(color: Ayu.bgSecondary, label: "Surface")
    ColorSwatch(color: Ayu.fgPrimary, label: "Text")
    ColorSwatch(color: Ayu.accent, label: "Accent")
}

struct ColorSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.xs)
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(Ayu.fgMuted.opacity(0.3), lineWidth: 1)
            )
            .accessibilityLabel(label)
    }
}
```

### Anti-Patterns to Avoid

- **Using `.colorScheme(_:)` instead of `.preferredColorScheme(_:)`:** The `.colorScheme()` modifier is deprecated and only affects the view and its children. `preferredColorScheme` propagates up to the enclosing presentation (window), which is the correct behavior.
- **Setting NSApp.appearance without preferredColorScheme:** AppKit appearance alone does NOT trigger SwiftUI `@Environment(\.colorScheme)` re-evaluation reliably in all cases. Both must be set.
- **Using `.environment(\.colorScheme, .dark)` for app-wide theming:** This override is for individual views only and does not affect sheets, popovers, or other presentations. Use `preferredColorScheme` for app-level control.
- **Observing DistributedNotificationCenter for system theme changes:** Unnecessary when `NSApp.appearance = nil` (system mode). Setting appearance to nil already tracks the OS appearance in real time. No notification observer is needed.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Theme persistence | Custom UserDefaults + onChange observer | `@AppStorage("appearanceMode")` with String-backed enum | @AppStorage is both persistence AND view invalidation; zero boilerplate |
| System appearance tracking | DistributedNotificationCenter observer for AppleInterfaceThemeChangedNotification | `NSApp.appearance = nil` + `preferredColorScheme(nil)` | Setting both to nil/nil automatically tracks OS changes in real time |
| Color scheme animation | Custom animation context or NSAnimationContext | `withAnimation(Motion.curveDefault) { appearanceMode = newValue }` | SwiftUI animates all dependent views automatically via state change |
| AppKit surface theming | Per-window or per-view NSAppearance overrides | `NSApp.appearance = NSAppearance(named:)` at app level | Single app-level setting propagates to ALL windows and AppKit surfaces |

**Key insight:** macOS SwiftUI theme switching is a 2-line problem (`preferredColorScheme` + `NSApp.appearance`) with `@AppStorage` for free persistence. The complexity is not in the mechanism but in ensuring coverage of all surfaces.

## Common Pitfalls

### Pitfall 1: preferredColorScheme Alone Misses AppKit Surfaces

**What goes wrong:** Date pickers, confirmation dialogs, and some sheet chrome remain in the system appearance despite `preferredColorScheme(.dark)` being set on the window content.

**Why it happens:** These controls bridge to AppKit under the hood. `preferredColorScheme` only affects SwiftUI's rendering context, not AppKit's `effectiveAppearance`.

**How to avoid:** Always set BOTH `preferredColorScheme` on window content AND `NSApp.appearance` at the app level. The STATE.md decision already captures this: "Theme switching requires both preferredColorScheme on WindowGroup AND NSApp.appearance for AppKit surfaces."

**Warning signs:** Date pickers or confirmation dialogs appearing in the wrong theme.

### Pitfall 2: Setting preferredColorScheme to nil Does Not Reset After Override

**What goes wrong:** After the user selects Dark, then switches back to System, the app may remain in dark mode because `preferredColorScheme(nil)` does not actively reset -- it merely removes the preference.

**Why it happens:** Known SwiftUI behavior where `nil` (no preference) does not force a re-evaluation if a non-nil value was previously set in the same view lifecycle.

**How to avoid:** Setting `NSApp.appearance = nil` simultaneously handles this case. When `NSApp.appearance` is nil, the OS appearance propagates to all windows including SwiftUI content. The dual-layer approach (Pattern 2) naturally resolves this because `NSApp.appearance = nil` forces AppKit to re-derive the appearance from the system setting.

**Warning signs:** App staying in dark mode after switching to "System" when the OS is in light mode.

### Pitfall 3: @AppStorage with Enum Requires RawRepresentable Conformance

**What goes wrong:** Attempting to use `@AppStorage` with an enum that doesn't have a String or Int raw value causes a compile error.

**Why it happens:** `@AppStorage` only supports `Bool`, `Int`, `Double`, `String`, `URL`, `Data`, and types conforming to `RawRepresentable` where `RawValue` is one of those types.

**How to avoid:** Declare `AppearanceMode: String, CaseIterable` with string raw values. `@AppStorage("appearanceMode") private var mode: AppearanceMode = .system` then works directly. `AppearanceMode` must also be `public` since it's in SharedUI and used in App.

**Warning signs:** Compile error "No exact matches in call to initializer" on @AppStorage line.

### Pitfall 4: Settings Window Not Receiving Theme Change

**What goes wrong:** Main window switches theme but the Settings window (opened via Cmd+,) stays in the old theme.

**Why it happens:** SwiftUI's `Settings` scene is a separate presentation from `WindowGroup`. `preferredColorScheme` applied to WindowGroup content does NOT propagate to the Settings scene.

**How to avoid:** Apply `preferredColorScheme(appearanceMode.colorScheme)` to the Settings scene content view as well. `NSApp.appearance` covers this at the AppKit level, but for SwiftUI `@Environment(\.colorScheme)` to update inside Settings, the modifier must be on both.

**Warning signs:** Settings window color scheme doesn't match main window after switching.

### Pitfall 5: Animation Not Applying to Theme Switch

**What goes wrong:** Theme switches instantly with no cross-fade, despite `withAnimation` being used.

**Why it happens:** `withAnimation` wraps a STATE change, not a side effect. If `NSApp.appearance` is set outside the animation block, or if `preferredColorScheme` is applied to a computed property that doesn't trigger a view update, the animation is lost.

**How to avoid:** The `@AppStorage` binding change IS the state change. When the Picker's binding updates `appearanceMode`, SwiftUI animates the resulting view re-render if `withAnimation` wraps the assignment. For the segmented picker, the binding update is automatic -- wrap the `onChange(of: appearanceMode)` handler with `withAnimation`.

**Warning signs:** Instantaneous theme switch with no visual transition.

### Pitfall 6: Forgetting `public` on AppearanceMode

**What goes wrong:** App target cannot see `AppearanceMode` type defined in SharedUI package.

**Why it happens:** SPM access control -- SharedUI types used in App must be `public`. This is the most common build error in the project (documented in CLAUDE.md).

**How to avoid:** Mark `AppearanceMode` enum, all its cases, all computed properties, and all protocol conformances as `public`.

**Warning signs:** "Cannot find type 'AppearanceMode' in scope" compile error in App target.

## Code Examples

Verified patterns from official SwiftUI documentation and project conventions:

### Complete AppearanceMode Enum (SharedUI)

```swift
// Source: SwiftUI @AppStorage + RawRepresentable — Apple Developer Documentation
// Pattern: matches project convention of public enums in SharedUI

/// User-selectable appearance mode for the app.
///
/// Persisted via `@AppStorage("appearanceMode")`. Maps to both
/// SwiftUI `ColorScheme?` and AppKit `NSAppearance?` for dual-layer coverage.
public enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// SwiftUI color scheme override. Returns nil for system (follow OS).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// SF Symbol name for the segmented picker.
    public var symbolName: String {
        switch self {
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        }
    }

    /// Accessibility label for VoiceOver.
    public var accessibilityLabel: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
```

### App Entry Point Integration

```swift
// Source: SwiftUI preferredColorScheme — Apple Developer Documentation
// Source: AppKit NSApp.appearance — Apple Developer Documentation

@main
struct GenreUpdaterApp: App {
    @State private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dependencies)
                .optionalModelContainer(dependencies.modelContainer)
                .preferredColorScheme(appearanceMode.colorScheme)
                .task {
                    await dependencies.initialize()
                    applyAppKitAppearance(appearanceMode)
                }
                .onChange(of: appearanceMode) { _, newMode in
                    applyAppKitAppearance(newMode)
                }
        }
        .defaultSize(width: 1280, height: 800)
        // ... existing commands

        Settings {
            SettingsView()
                .environment(dependencies)
                .preferredColorScheme(appearanceMode.colorScheme)
                .frame(minWidth: 520, idealWidth: 520, maxWidth: 520, minHeight: 400)
        }
    }

    private func applyAppKitAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
```

### Appearance Tab in SettingsView

```swift
// Source: SwiftUI Picker + .segmented — Apple Developer Documentation
// Pattern: matches existing Settings tab structure

private struct AppearanceTab: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.symbolName)
                            .accessibilityLabel(mode.accessibilityLabel)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                // Color preview swatches
                HStack(spacing: Spacing.xs) {
                    ColorSwatch(color: Ayu.bgPrimary, label: "Background")
                    ColorSwatch(color: Ayu.bgSecondary, label: "Surface")
                    ColorSwatch(color: Ayu.fgPrimary, label: "Text")
                    ColorSwatch(color: Ayu.accent, label: "Accent")
                }
                .padding(.top, Spacing.xxs)
            }

            Section("Sidebar Style") {
                Text("Coming in a future update")
                    .foregroundStyle(Ayu.fgMuted)
                    .font(AppFont.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

### Cross-Fade Animation on Theme Change

```swift
// The animation happens automatically because:
// 1. @AppStorage triggers view invalidation when the value changes
// 2. .preferredColorScheme is re-evaluated with the new value
// 3. SwiftUI animates the resulting color transitions

// For explicit animation wrapping (e.g. if using a custom binding):
.onChange(of: appearanceMode) { _, _ in
    withAnimation(Motion.curveDefault) {
        // State change already happened via @AppStorage binding
        // withAnimation wraps the re-render, not the assignment
    }
}

// Note: SwiftUI automatically animates Color changes when
// preferredColorScheme changes, because Color.adaptive() resolves
// to different NSColor values under different appearances.
// The ~0.3s cross-fade comes from Motion.curveDefault (300ms easeInOut).
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `.colorScheme(_:)` modifier | `.preferredColorScheme(_:)` | iOS 13 (deprecated), macOS 11+ replacement | `preferredColorScheme` propagates to enclosing presentation; `.colorScheme` is view-scoped and deprecated |
| Manual UserDefaults + KVO for theme persistence | `@AppStorage` with RawRepresentable enum | SwiftUI 2.0 (2020) | Zero-boilerplate persistence + view invalidation |
| DistributedNotificationCenter for system theme changes | `NSApp.appearance = nil` | Always available in AppKit | Setting to nil auto-tracks OS; no notification observer needed |
| Per-window NSAppearance overrides | `NSApp.appearance` at app level | Always available in AppKit | Single setting propagates to all windows and AppKit surfaces |

**Deprecated/outdated:**
- `.colorScheme(_:)` modifier: Deprecated as of iOS 13.0-26.4 across all Apple platforms. Use `.preferredColorScheme(_:)` instead.
- Manual `DistributedNotificationCenter.default().addObserver(forName: "AppleInterfaceThemeChangedNotification")`: Unnecessary when `NSApp.appearance = nil` is used for system mode.

## Open Questions

1. **withAnimation on preferredColorScheme changes**
   - What we know: `preferredColorScheme` triggers a re-render when the bound value changes. SwiftUI generally animates Color transitions when `.animation()` is present. The user wants a ~0.3s cross-fade.
   - What's unclear: Whether `preferredColorScheme` changes are inherently animatable by `withAnimation`, or whether the animation only affects Color values that depend on `@Environment(\.colorScheme)`.
   - Recommendation: Apply `.animation(Motion.curveDefault, value: appearanceMode)` on the root view as a safety net. If SwiftUI natively cross-fades the scheme change, the explicit animation is harmless (same timing). If it doesn't, the explicit animation provides the cross-fade. Verify during implementation.

2. **Reduce motion for theme switch animation**
   - What we know: All animations in this project must respect `@Environment(\.accessibilityReduceMotion)` per Phase 1 decisions.
   - What's unclear: Whether a theme switch animation should be disabled under reduce motion, or whether a color change is considered non-motion and therefore exempt.
   - Recommendation: Respect reduce motion -- use instant switch when the accessibility setting is enabled. Theme switching is a visual transition, not informational content, so skipping animation is appropriate.

## Sources

### Primary (HIGH confidence)
- [SwiftUI `preferredColorScheme(_:)` documentation](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)) -- modifier behavior, nil semantics, enclosing presentation scope
- [SwiftUI `ColorScheme` documentation](https://developer.apple.com/documentation/swiftui/colorscheme) -- @Environment(\.colorScheme) for reading current scheme
- [SwiftUI `@AppStorage` documentation](https://developer.apple.com/documentation/swiftui/appstorage) -- RawRepresentable support for enum persistence
- [SwiftUI Settings scene documentation](https://developer.apple.com/documentation/swiftui/settings) -- separate scene requiring its own preferredColorScheme
- Context7 `/websites/developer_apple_swiftui` -- verified preferredColorScheme API, @AppStorage with RawRepresentable, Settings scene configuration

### Secondary (MEDIUM confidence)
- [Workarounds for reliable color scheme switching](https://write.as/angelo/workarounds-or-how-to-get-reliable-color-scheme-switching-in-swiftui-apps) -- confirms dual-layer approach (NSApp.appearance + preferredColorScheme); documents preferredColorScheme nil-reset bug
- [preferredColorScheme not affecting DatePicker](https://www.hackingwithswift.com/forums/swiftui/preferredcolorscheme-not-affecting-datepicker-and-confirmationdialog/11796) -- confirms AppKit surface gap requiring NSApp.appearance
- [Nil Coalescing: Reading and setting color scheme](https://nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/) -- overview of environment-based vs modifier-based approach

### Project-Verified (HIGH confidence)
- `AyuColors.swift` -- verified `Color.adaptive()` pattern resolves via `NSColor` appearance callback; will auto-adapt to appearance changes
- `DesignTokens.swift` -- verified `ShadowToken` references `Ayu.accent.opacity()` which is adaptive; no shadow changes needed
- `GenreUpdaterApp.swift` -- verified current structure: WindowGroup + Settings scenes, no existing appearance modifiers
- `SettingsView.swift` -- verified current 3-tab structure (General, API & Cache, Advanced); new tab inserts as 4th
- `AppDependencies.swift` -- verified @Observable + @MainActor pattern; no theme-related state exists yet
- `MainView.swift` -- verified NavigationSplitView structure; inherits appearance from parent

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- pure Apple frameworks already in project; no new dependencies
- Architecture: HIGH -- dual-layer pattern (preferredColorScheme + NSApp.appearance) is the documented standard; confirmed by multiple independent sources
- Color system compatibility: HIGH -- verified by reading AyuColors.swift Color.adaptive() implementation
- Pitfalls: HIGH -- AppKit surface gap confirmed by Hacking with Swift forum + write.as article; nil-reset behavior confirmed by same sources
- Animation: MEDIUM -- withAnimation + preferredColorScheme cross-fade behavior needs implementation-time verification

**Research date:** 2026-02-22
**Valid until:** 2026-08-22 (6 months -- stable Apple APIs, established patterns)
