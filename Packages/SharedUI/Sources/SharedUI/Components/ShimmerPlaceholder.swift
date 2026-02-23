// ShimmerPlaceholder.swift — Shimmer loading placeholder for skeleton screens.

@preconcurrency import Shimmer
import SwiftUI

// MARK: - ShimmerShape

/// Defines the shape variant for a shimmer placeholder.
public enum ShimmerShape: Sendable {
    /// Generic rectangular placeholder with specified dimensions.
    case rectangle(width: CGFloat, height: CGFloat)
    /// Circular placeholder for avatars or icons.
    case circle(diameter: CGFloat)
    /// Half-circle arc matching HeroGauge silhouette.
    case gauge
    /// StatCard-shaped rectangle spanning full available width.
    case card
    /// Quick-action row filling parent width via `maxWidth: .infinity`.
    case quickAction(height: CGFloat)
}

// MARK: - ShimmerPlaceholder

/// A skeleton loading placeholder that displays a shimmer animation.
///
/// Use during data loading to indicate content shape before it arrives.
/// Supports four shape variants matching common UI element silhouettes.
public struct ShimmerPlaceholder: View {
    private let shape: ShimmerShape

    public init(shape: ShimmerShape) {
        self.shape = shape
    }

    public var body: some View {
        shapeView
            .shimmering(
                gradient: Gradient(colors: [
                    .clear,
                    Ayu.bgSecondary.opacity(0.5),
                    .clear,
                ])
            )
    }

    @ViewBuilder
    private var shapeView: some View {
        switch shape {
        case let .rectangle(width, height):
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Ayu.bgTertiary)
                .frame(width: width, height: height)

        case let .circle(diameter):
            Circle()
                .fill(Ayu.bgTertiary)
                .frame(width: diameter, height: diameter)

        case .gauge:
            GaugeArc()
                .fill(Ayu.bgTertiary)
                .frame(width: 120, height: 60)

        case .card:
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.bgTertiary)
                .frame(height: 80)
                .frame(maxWidth: .infinity)

        case let .quickAction(height):
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.bgTertiary)
                .frame(height: height)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - GaugeArc

/// A 180-degree arc shape matching HeroGauge silhouette.
private struct GaugeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width / 2, rect.height)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview("Shimmer Placeholders") {
    VStack(spacing: Spacing.md) {
        ShimmerPlaceholder(shape: .rectangle(width: 200, height: 20))
        ShimmerPlaceholder(shape: .circle(diameter: 48))
        ShimmerPlaceholder(shape: .gauge)
        ShimmerPlaceholder(shape: .card)
        ShimmerPlaceholder(shape: .quickAction(height: 44))
    }
    .padding()
}
