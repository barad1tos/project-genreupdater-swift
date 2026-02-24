// ShakeModifier.swift — Horizontal shake effect for error feedback.

import SwiftUI

// MARK: - Shake Effect

/// A geometry effect that produces a horizontal oscillation.
///
/// Each unit increment of `shakeCount` produces 3 full sine-wave oscillations
/// with a maximum displacement of 6pt. Pair with `.shake(trigger:)` for usage.
struct ShakeEffect: GeometryEffect {
    var shakeCount: CGFloat

    var animatableData: CGFloat {
        get { shakeCount }
        set { shakeCount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // 3 oscillations per unit: multiply by 6 (3 * 2pi)
        let translation = sin(shakeCount * .pi * 6) * 6
        return ProjectionTransform(
            CGAffineTransform(translationX: translation, y: 0)
        )
    }
}

// MARK: - View Extension

extension View {
    /// Applies a horizontal shake animation when `trigger` changes.
    ///
    /// Increment `trigger` by 1 to fire 3 oscillations. The animation uses a
    /// spring with slight bounce for organic decay.
    ///
    /// - Parameters:
    ///   - trigger: Increment to fire the shake. Each increment produces 3 oscillations.
    ///   - reduceMotion: Pass `true` to disable the shake (respects accessibility).
    @ViewBuilder
    public func shake(trigger: Int, reduceMotion: Bool = false) -> some View {
        if reduceMotion {
            self
        } else {
            modifier(ShakeEffect(shakeCount: CGFloat(trigger)))
                .animation(.spring(duration: 0.4, bounce: 0.3), value: trigger)
        }
    }
}
