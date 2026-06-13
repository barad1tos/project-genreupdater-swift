// DesignTokens.swift — Spacing, corner radius, and typography design tokens.

import SwiftUI

// MARK: - Spacing

/// Base-4 spacing scale for consistent layout.
public enum Spacing {
    /// 4pt — minimal gap between inline elements.
    public static let xxs: CGFloat = 4
    /// 8pt — tight padding within compact components.
    public static let xs: CGFloat = 8
    /// 12pt — standard inline spacing.
    public static let sm: CGFloat = 12
    /// 16pt — default content padding.
    public static let md: CGFloat = 16
    /// 20pt — section spacing within cards.
    public static let lg: CGFloat = 20
    /// 24pt — gap between cards and sections.
    public static let xl: CGFloat = 24
    /// 32pt — major layout section spacing.
    public static let xxl: CGFloat = 32
    /// 40pt — screen-level section breaks.
    public static let xxxl: CGFloat = 40
    /// 48pt — hero element padding.
    public static let huge: CGFloat = 48
    /// 64pt — maximum spacing for dashboard layout.
    public static let max: CGFloat = 64
}

// MARK: - Corner Radius

/// Consistent corner radius scale.
public enum Radius {
    /// 4pt — badges, pills.
    public static let xs: CGFloat = 4
    /// 8pt — cards, buttons.
    public static let sm: CGFloat = 8
    /// 12pt — panels, grouped content.
    public static let md: CGFloat = 12
    /// 16pt — sheets, modals.
    public static let lg: CGFloat = 16
    /// 20pt — overlays.
    public static let xl: CGFloat = 20
}

// MARK: - Typography

/// Semantic font definitions for consistent typography.
public enum AppFont {
    /// Large gauge numbers — 48pt bold rounded.
    public static let display: Font = .system(size: 48, weight: .bold, design: .rounded)
    /// Section headers.
    public static let headline: Font = .title2.bold()
    /// Card titles.
    public static let subheadline: Font = .headline
    /// Content text.
    public static let body: Font = .body
    /// Labels, badges.
    public static let caption: Font = .caption
    /// Track IDs, technical values.
    public static let mono: Font = .system(.body, design: .monospaced)
    /// Metric values — 32pt bold rounded.
    public static let metric: Font = .system(size: 32, weight: .bold, design: .rounded)
    /// Small metric values — 24pt bold rounded.
    public static let metricSmall: Font = .system(size: 24, weight: .bold, design: .rounded)
}

// MARK: - Liquid Glass

extension View {
    /// Applies Liquid Glass styling when running on macOS 26+.
    ///
    /// On earlier systems, this is a no-op — the view renders unchanged.
    /// Use on individual elements (cards, toolbars, floating panels) — NOT on container views
    /// like `NavigationSplitView` which get system-level glass automatically.
    @ViewBuilder
    public func applyLiquidGlass(
        in shape: some Shape = .rect(cornerRadius: Radius.md)
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Applies tinted Liquid Glass with the given color.
    @ViewBuilder
    public func applyTintedGlass(
        _ tint: Color,
        in shape: some Shape = .rect(cornerRadius: Radius.md)
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Shadow

/// A shadow definition for use with `.ayuShadow(_:)`.
public struct ShadowToken: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
}

/// Elevation-based shadow tokens using Ayu accent tinting.
///
/// All shadows use soft/diffuse spread (large blur, wide offset) matching Apple/Spotify aesthetic.
/// Tinted with `Ayu.accent.opacity(...)` for brand identity in both themes.
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
    /// Pressed/inset button state — subtle negative-Y offset trick.
    public static let inner = ShadowToken(
        color: Ayu.accent.opacity(0.15),
        radius: 4,
        x: 0,
        y: -2
    )
}

extension View {
    /// Applies an Ayu elevation shadow from the design token system.
    ///
    /// Prefer this over raw `.shadow(color:radius:x:y:)` — tokens are the single source of truth.
    public func ayuShadow(_ token: ShadowToken) -> some View {
        shadow(
            color: token.color,
            radius: token.radius,
            x: token.x,
            y: token.y
        )
    }
}

// MARK: - Motion

/// Duration and easing constants for consistent animations.
///
/// Use `Motion.*` instead of raw literals in `.animation()` calls.
/// Pair with `.motionAnimation(_:value:reduceMotion:)` to respect macOS "Reduce Motion".
public enum Motion {
    // MARK: Durations

    /// 200ms — immediate feedback (hover, press).
    public static let durationFast: Double = 0.2
    /// 300ms — standard transitions (content swap, panel slide).
    public static let durationNormal: Double = 0.3
    /// 350ms — sidebar and layout transitions.
    public static let durationSmooth: Double = 0.35
    /// 400ms — emphasized transitions (modal appear, loading complete).
    public static let durationEmphasis: Double = 0.4
    /// 500ms — shimmer-to-content crossfade transition.
    public static let durationCrossfade: Double = 0.5

    // MARK: Curves

    /// easeInOut 300ms — symmetrical entry and exit; default for most transitions.
    public static let curveDefault: Animation = .easeInOut(duration: durationNormal)
    /// easeOut 300ms — fast start, graceful stop; use for elements appearing.
    public static let curveAppear: Animation = .easeOut(duration: durationNormal)
    /// easeInOut 200ms — hover and press feedback.
    public static let curveFast: Animation = .easeInOut(duration: durationFast)
    /// easeInOut 350ms — sidebar pill slide and layout transitions.
    public static let curveSmooth: Animation = .easeInOut(duration: durationSmooth)
    /// easeInOut 400ms — modal and sheet entrance.
    public static let curveEmphasis: Animation = .easeInOut(duration: durationEmphasis)
    /// easeInOut 500ms — shimmer-to-content crossfade transition.
    public static let curveCrossfade: Animation = .easeInOut(duration: durationCrossfade)
    /// easeInOut 250ms — layout column visibility changes.
    public static let curveLayout: Animation = .easeInOut(duration: 0.25)

    // MARK: Card Lift

    /// Card lift spring — slight overshoot for physical lift feel.
    public static let cardLiftSpring: Animation = .spring(
        response: 0.45,
        dampingFraction: 0.75,
        blendDuration: 0.1
    )

    /// Pre-lift press-in — fast, critically damped, no bounce.
    public static let pressInCurve: Animation = .spring(
        response: 0.15,
        dampingFraction: 1.0,
        blendDuration: 0
    )

    // MARK: Phase 8 Additions

    /// easeOut 800ms — HeroGauge arc draw-in (signature wow moment).
    public static let curveGaugeFill: Animation = .easeOut(duration: 0.8)

    /// Spring with slight overshoot — organic element appearances (chart bars, gauge arcs).
    public static let springOrganic: Animation = .spring(
        response: 0.5,
        dampingFraction: 0.7,
        blendDuration: 0.1
    )

    /// Bouncy spring — QuickAction scale bounce, ConfidenceBadge pop-in.
    public static let springBounce: Animation = .spring(
        response: 0.35,
        dampingFraction: 0.6,
        blendDuration: 0
    )

    // MARK: Scaling

    /// Returns the animation with its speed adjusted by the given scale factor.
    ///
    /// A scale of 0.5 doubles animation speed (halving durations).
    /// Used with the `motionScale` environment value for the "Fast Animations" toggle.
    public static func scaled(_ animation: Animation, by scale: Double) -> Animation {
        animation.speed(1.0 / max(scale, 0.01))
    }
}

extension EnvironmentValues {
    /// Multiplier for animation durations. Default 1.0; set to 0.5 for "Fast Animations".
    @Entry public var motionScale: Double = 1.0
}

extension View {
    /// Applies an animation that respects macOS "Reduce Motion" accessibility setting.
    ///
    /// When reduce motion is enabled, uses `.default` (instant) so users who need
    /// reduced motion are not affected. Pass `reduceMotion` from
    /// `@Environment(\.accessibilityReduceMotion)` at the call site.
    public func motionAnimation(
        _ animation: Animation,
        value: some Equatable,
        reduceMotion: Bool
    ) -> some View {
        self.animation(reduceMotion ? .default : animation, value: value)
    }
}
