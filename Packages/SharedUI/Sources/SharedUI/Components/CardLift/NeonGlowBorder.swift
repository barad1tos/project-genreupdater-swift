// NeonGlowBorder.swift -- Breathing glow border with layered shadows for card lift.

import SwiftUI

// MARK: - Neon Glow Border

/// Animated border overlay with layered neon glow effect.
///
/// Renders a rounded rectangle stroke with three shadow layers at increasing radii.
/// In dark mode the glow is vivid; in light mode opacity is reduced by 40%.
/// Respects `accessibilityReduceMotion` by showing a static glow at 0.55 opacity.
///
/// Hit testing is disabled -- all clicks pass through to underlying content.
public struct NeonGlowBorder: View {
    private let color: Color
    private let cornerRadius: CGFloat
    private let lineWidth: CGFloat
    private let isActive: Bool

    @State private var glowOpacity: CGFloat = 0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(
        color: Color,
        cornerRadius: CGFloat,
        lineWidth: CGFloat = 1,
        isActive: Bool = true
    ) {
        self.color = color
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        self.isActive = isActive
    }

    /// Multiplier for glow intensity: vivid in dark mode, muted in light.
    private var modeMultiplier: CGFloat {
        colorScheme == .dark ? 1.0 : 0.6
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(color.opacity(glowOpacity * modeMultiplier), lineWidth: lineWidth)
            .shadow(color: color.opacity(glowOpacity * 0.8 * modeMultiplier), radius: 4)
            .shadow(color: color.opacity(glowOpacity * 0.6 * modeMultiplier), radius: 8)
            .shadow(color: color.opacity(glowOpacity * 0.4 * modeMultiplier), radius: 16)
            .allowsHitTesting(false)
            .onAppear {
                guard isActive else { return }
                if reduceMotion {
                    glowOpacity = 0.55
                } else {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                            .repeatForever(autoreverses: true)
                    ) {
                        glowOpacity = 0.7
                    }
                }
            }
    }
}
