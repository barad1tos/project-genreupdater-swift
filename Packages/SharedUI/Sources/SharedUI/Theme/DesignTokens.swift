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
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
        }
    }

    /// Applies tinted Liquid Glass with the given color.
    @ViewBuilder
    public func applyTintedGlass(
        _ tint: Color,
        in shape: some Shape = .rect(cornerRadius: Radius.md)
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self
        }
    }
}
