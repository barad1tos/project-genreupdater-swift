// AyuColors.swift — Ayu-inspired color tokens for light and dark themes.

import SwiftUI

// MARK: - Ayu Color Tokens

/// Centralized color palette based on the ayu editor theme.
///
/// Provides adaptive colors that resolve to ayu-light or ayu-mirage variants
/// depending on the current `colorScheme`. Access via `Color.ayu.*` namespace.
public enum Ayu {
    // MARK: Background

    /// Primary window background.
    public static let bgPrimary = Color("AyuBgPrimary", bundle: nil)
        .fallback(light: hex(0xFCFCFC), dark: hex(0x242936))

    /// Card and sidebar backgrounds.
    public static let bgSecondary = Color.adaptive(
        light: hex(0xF3F4F5),
        dark: hex(0x1A1F29)
    )

    /// Hover states and dividers.
    public static let bgTertiary = Color.adaptive(
        light: hex(0xE8E9EB),
        dark: hex(0x3A3F4B)
    )

    // MARK: Foreground

    /// Body text.
    public static let fgPrimary = Color.adaptive(
        light: hex(0x5C6166),
        dark: hex(0xCCCAC2)
    )

    /// Captions and placeholders.
    public static let fgSecondary = Color.adaptive(
        light: hex(0x8A9199),
        dark: hex(0x8A9199)
    )

    /// Disabled and muted text.
    public static let fgMuted = Color.adaptive(
        light: hex(0x787B80),
        dark: hex(0xB8CFE6).opacity(0.5)
    )

    // MARK: Accent

    /// Primary accent — CTA, gauges, highlights.
    public static let accent = Color.adaptive(
        light: hex(0xFFAA33),
        dark: hex(0xFFCC66)
    )

    /// Secondary warm accent.
    public static let accentSecondary = Color.adaptive(
        light: hex(0xF2AE49),
        dark: hex(0xFFD173)
    )

    // MARK: Semantic

    /// Success, high confidence (80%+).
    public static let success = Color.adaptive(
        light: hex(0x86B300),
        dark: hex(0xD5FF80)
    )

    /// Info, tags, entities, year updates.
    public static let info = Color.adaptive(
        light: hex(0x55B4D4),
        dark: hex(0x5CCFE6)
    )

    /// Warnings, medium confidence (50-79%).
    public static let warning = Color.adaptive(
        light: hex(0xFA8D3E),
        dark: hex(0xFFAD66)
    )

    /// Errors, low confidence (<50%).
    public static let error = Color.adaptive(
        light: hex(0xE65050),
        dark: hex(0xFF6666)
    )

    /// Constants, genre badges.
    public static let purple = Color.adaptive(
        light: hex(0xA37ACC),
        dark: hex(0xDFBFFF)
    )

    /// Artist-related elements.
    public static let teal = Color.adaptive(
        light: hex(0x4CBF99),
        dark: hex(0x95E6CB)
    )

    /// Selected item background.
    public static let selection = Color.adaptive(
        light: hex(0x036DD6).opacity(0.15),
        dark: hex(0x3388FF).opacity(0.25)
    )

    // MARK: Confidence

    /// Returns the ayu color for a given confidence value (0.0–1.0).
    public static func confidence(_ value: Double) -> Color {
        switch value {
        case 0.8 ... 1.0: success
        case 0.5 ..< 0.8: warning
        default: error
        }
    }

    /// Foreground color appropriate for confidence badge text.
    public static func confidenceForeground(_ value: Double) -> Color {
        switch value {
        case 0.5 ..< 0.8:
            Color.adaptive(light: hex(0x5C6166), dark: hex(0x242936))
        default:
            .white
        }
    }

    // MARK: Change Type

    /// Color for a specific change type.
    public static func changeType(_ name: String) -> Color {
        switch name.lowercased() {
        case "genre": purple
        case "year": info
        case "track", "album": accent
        case "artist": teal
        case "revert": error
        default: fgSecondary
        }
    }

    // MARK: Tier

    /// Color for subscription tier badges.
    public static func tier(_ name: String) -> Color {
        switch name.lowercased() {
        case "free": fgMuted
        case "weekpass", "week pass": info
        case "pro": accent
        default: fgSecondary
        }
    }
}

// MARK: - Color Helpers

extension Color {
    /// Creates an adaptive color that resolves to light/dark variants.
    static func adaptive(light: Color, dark: Color) -> Color {
        // Uses NSColor under the hood for proper dark mode support on macOS
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }

    /// Fallback for asset catalog colors — returns adaptive equivalent.
    func fallback(light: Color, dark: Color) -> Color {
        Color.adaptive(light: light, dark: dark)
    }
}

/// Creates a Color from a hex integer (e.g., `0xFFAA33`).
private func hex(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}
