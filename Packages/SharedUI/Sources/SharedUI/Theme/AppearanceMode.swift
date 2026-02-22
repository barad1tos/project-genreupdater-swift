// AppearanceMode.swift — User-selectable appearance preference (Dark / Light / System).

import SwiftUI

// MARK: - Appearance Mode

/// Three-way appearance preference stored via `@AppStorage`.
///
/// `.system` follows the OS appearance in real time. `.light` and `.dark` pin a
/// specific color scheme regardless of system settings. The raw value is the
/// `@AppStorage` key format (lowercase string).
public enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// SwiftUI `ColorScheme` for `preferredColorScheme(_:)`.
    ///
    /// Returns `nil` for `.system` so SwiftUI falls through to the OS setting.
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
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// VoiceOver label for accessibility.
    public var accessibilityLabel: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
