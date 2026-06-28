import SwiftUI

// MARK: - Ayu palette (Mirage)
// Central color tokens. Replace hex values with your canonical AyuColors if you
// already have them; names are kept descriptive so call sites read clearly.
enum Ayu {
    static let window    = Color(hex: 0x242936)
    static let card      = Color(hex: 0x1A1F29)
    static let editor    = Color(hex: 0x1F2430)
    static let hover     = Color(hex: 0x3A3F4B)
    static let borderL   = Color(hex: 0x2B3245)

    static let fg        = Color(hex: 0xCCCAC2)
    static let fg2       = Color(hex: 0x8A9199)
    static let fgMuted   = Color(hex: 0x6C7380)

    static let accent    = Color(hex: 0xFFCC66)
    static let accent2   = Color(hex: 0xFFD173)
    static let onAccent  = Color(hex: 0x1F2430)

    static let success   = Color(hex: 0xD5FF80)
    static let info      = Color(hex: 0x5CCFE6)
    static let warning   = Color(hex: 0xFFAD66)
    static let error     = Color(hex: 0xFF6666)
    static let purple    = Color(hex: 0xDFBFFF)
    static let teal      = Color(hex: 0x95E6CB)

    static var track: Color { .white.opacity(0.07) }
    static var glassHi: Color { .white.opacity(0.10) }
    static var glassBorder: Color { .white.opacity(0.085) }

    /// Leading-edge color of the health ruler, keyed to bands.
    static func band(_ v: Double) -> Color {
        v >= 0.85 ? success : v >= 0.65 ? info : v >= 0.40 ? warning : error
    }
}

// MARK: - Semantic tones
enum Tone {
    case neutral, info, success, warning, error, accent, purple, teal
    var color: Color {
        switch self {
        case .neutral: return Ayu.fg2
        case .info:    return Ayu.info
        case .success: return Ayu.success
        case .warning: return Ayu.warning
        case .error:   return Ayu.error
        case .accent:  return Ayu.accent
        case .purple:  return Ayu.purple
        case .teal:    return Ayu.teal
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8)  & 0xff) / 255,
                  blue:  Double( hex        & 0xff) / 255)
    }
}

// MARK: - Type helpers
extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
