import SwiftUI

// MARK: - Ayu palette (Mirage)

/// Central color tokens. Replace hex values with your canonical AyuColors if you
/// already have them; names are kept descriptive so call sites read clearly.
enum Ayu {
    static let window = Color(hex: 0x242936)
    static let card = Color(hex: 0x1A1F29)
    static let editor = Color(hex: 0x1F2430)
    static let hover = Color(hex: 0x343A46)
    static let borderL = Color(hex: 0x2B3245)

    static let fg = Color(hex: 0xCCCAC2)
    static let fg2 = Color(hex: 0x8A9199)
    static let fgMuted = Color(hex: 0x6C7380)

    static let accent = Color(hex: 0xFFCC66)
    static let accent2 = Color(hex: 0xFFD173)
    static let onAccent = Color(hex: 0x1F2430)

    static let success = Color(hex: 0xD5FF80)
    static let info = Color(hex: 0x5CCFE6)
    static let warning = Color(hex: 0xFFAD66)
    static let error = Color(hex: 0xFF6666)
    static let purple = Color(hex: 0xDFBFFF)
    static let teal = Color(hex: 0x95E6CB)

    static var surface: Color {
        editor.opacity(0.72)
    }
    static var surfaceRaised: Color {
        card.opacity(0.92)
    }
    static var controlFill: Color {
        .white.opacity(0.055)
    }
    static var controlFillStrong: Color {
        .white.opacity(0.085)
    }
    static var selectionFill: Color {
        accent.opacity(0.15)
    }
    static var track: Color {
        .white.opacity(0.055)
    }
    static var glassHi: Color {
        .white.opacity(0.075)
    }
    static var glassBorder: Color {
        .white.opacity(0.075)
    }
    static var glassBorderStrong: Color {
        .white.opacity(0.12)
    }

    /// Leading-edge color of the health ruler, keyed to bands.
    static func band(_ value: Double) -> Color {
        value >= 0.85 ? success : value >= 0.65 ? info : value >= 0.40 ? warning : error
    }
}

// MARK: - Semantic tones

public enum Tone: Equatable, Sendable {
    case neutral, info, success, warning, error, accent, purple, teal

    var color: Color {
        switch self {
        case .neutral: Ayu.fg2
        case .info: Ayu.info
        case .success: Ayu.success
        case .warning: Ayu.warning
        case .error: Ayu.error
        case .accent: Ayu.accent
        case .purple: Ayu.purple
        case .teal: Ayu.teal
        }
    }

    var pillFill: Color {
        switch self {
        case .neutral:
            Ayu.controlFill
        case .accent, .warning:
            color.opacity(0.12)
        case .error:
            color.opacity(0.13)
        default:
            color.opacity(0.09)
        }
    }

    var pillBorder: Color {
        switch self {
        case .neutral:
            Ayu.glassBorder
        case .accent, .warning, .error:
            color.opacity(0.24)
        default:
            color.opacity(0.18)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Type helpers

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
