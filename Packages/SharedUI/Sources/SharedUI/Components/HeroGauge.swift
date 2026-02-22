// HeroGauge.swift — Half-circle concentric arc gauge with draw-in animation.

import SwiftUI

// MARK: - ArcShape

/// Half-circle arc that fills from left to right based on progress.
///
/// The arc opens upward with its center at the bottom of the rect.
/// Conforms to `Animatable` for smooth interpolation during animations.
private struct ArcShape: Shape, Animatable {
    var progress: Double
    let radius: CGFloat
    let lineWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let startAngle = Angle.degrees(180)
        let endAngle = Angle.degrees(180 + 180 * progress)

        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

// MARK: - GaugeLayer

/// Identifies a concentric arc layer within the gauge.
private enum GaugeLayer: CaseIterable, Sendable {
    case genre
    case year
    case consistency

    var color: Color {
        switch self {
        case .genre: Ayu.accent
        case .year: Ayu.success
        case .consistency: Ayu.info
        }
    }

    var label: String {
        switch self {
        case .genre: "Genre"
        case .year: "Year"
        case .consistency: "Consistency"
        }
    }
}

// MARK: - HeroGauge

/// Dashboard hero gauge showing library health as three concentric half-circle arcs.
///
/// Displays genre, year, and consistency coverage as concentric arcs opening
/// upward. Animates on appear and supports per-arc hover to show layer details.
///
/// Accepts only plain types — no Core model dependency.
public struct HeroGauge: View {
    private let genreCoverage: Double
    private let yearCoverage: Double
    private let consistencyCoverage: Double
    private let trackCount: Int

    @State private var animatedGenre: Double = 0
    @State private var animatedYear: Double = 0
    @State private var animatedConsistency: Double = 0
    @State private var hoveredLayer: GaugeLayer?

    private let arcLineWidth: CGFloat = 16
    private let arcGap: CGFloat = 6

    public init(
        genreCoverage: Double,
        yearCoverage: Double,
        consistencyCoverage: Double,
        trackCount: Int
    ) {
        self.genreCoverage = genreCoverage
        self.yearCoverage = yearCoverage
        self.consistencyCoverage = consistencyCoverage
        self.trackCount = trackCount
    }

    public var body: some View {
        VStack(spacing: Spacing.md) {
            arcArea
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Library health gauge")
        .accessibilityValue(accessibilityDescription)
    }

    // MARK: - Arc Area

    private var arcArea: some View {
        GeometryReader { geometry in
            let maxRadius = maxRadius(for: geometry.size)

            ZStack {
                arcs(maxRadius: maxRadius)
                centerContent(in: geometry.size)
            }
            .onContinuousHover { phase in
                handleHover(
                    phase,
                    in: geometry.size,
                    maxRadius: maxRadius
                )
            }
        }
        .onAppear(perform: animateDrawIn)
    }

    // MARK: - Arcs

    @ViewBuilder
    private func arcs(maxRadius: CGFloat) -> some View {
        let layers: [(GaugeLayer, CGFloat, Double)] = [
            (.genre, maxRadius, animatedGenre),
            (
                .year,
                maxRadius - arcLineWidth - arcGap,
                animatedYear
            ),
            (
                .consistency,
                maxRadius - 2 * (arcLineWidth + arcGap),
                animatedConsistency
            ),
        ]

        ForEach(
            Array(layers.enumerated()),
            id: \.offset
        ) { _, item in
            let (layer, radius, animated) = item

            // Background track
            ArcShape(
                progress: 1.0,
                radius: radius,
                lineWidth: arcLineWidth
            )
            .stroke(
                layer.color.opacity(0.15),
                style: StrokeStyle(
                    lineWidth: arcLineWidth,
                    lineCap: .butt
                )
            )

            // Value arc
            ArcShape(
                progress: animated,
                radius: radius,
                lineWidth: arcLineWidth
            )
            .stroke(
                layer.color,
                style: StrokeStyle(
                    lineWidth: arcLineWidth,
                    lineCap: .butt
                )
            )
        }
    }

    // MARK: - Center Content

    private func centerContent(in size: CGSize) -> some View {
        VStack(spacing: Spacing.xxs) {
            if let layer = hoveredLayer {
                Text("\(Int(coverage(for: layer) * 100))%")
                    .font(AppFont.display)
                    .contentTransition(.numericText())
                Text(layer.label)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
            } else {
                Text(trackCount.formatted())
                    .font(AppFont.display)
                    .contentTransition(.numericText())
                Text("tracks")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
            }
        }
        .animation(Motion.curveFast, value: hoveredLayer)
        .position(x: size.width / 2, y: size.height)
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Spacing.lg) {
            legendItem(
                layer: .genre,
                coverage: genreCoverage
            )
            legendItem(
                layer: .year,
                coverage: yearCoverage
            )
            legendItem(
                layer: .consistency,
                coverage: consistencyCoverage
            )
        }
    }

    private func legendItem(
        layer: GaugeLayer,
        coverage: Double
    ) -> some View {
        HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(layer.color)
                .frame(width: 8, height: 8)
            Text(layer.label)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
            Text("\(Int(coverage * 100))%")
                .font(AppFont.caption.bold())
                .foregroundStyle(Ayu.fgPrimary)
        }
    }

    // MARK: - Hover Detection

    private func handleHover(
        _ phase: HoverPhase,
        in size: CGSize,
        maxRadius: CGFloat
    ) {
        switch phase {
        case let .active(location):
            let center = CGPoint(
                x: size.width / 2,
                y: size.height
            )
            let deltaX = location.x - center.x
            let deltaY = location.y - center.y

            // Only detect in upper half (arcs open upward)
            guard deltaY <= 0 else {
                hoveredLayer = nil
                return
            }

            let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
            let halfWidth = arcLineWidth / 2

            let genreRadius = maxRadius
            let yearRadius = maxRadius - arcLineWidth - arcGap
            let consistencyRadius = maxRadius - 2 * (arcLineWidth + arcGap)

            let genreRange = (genreRadius - halfWidth) ... (genreRadius + halfWidth)
            let yearRange = (yearRadius - halfWidth) ... (yearRadius + halfWidth)
            let consistencyRange = (consistencyRadius - halfWidth) ... (consistencyRadius + halfWidth)

            if genreRange.contains(distance) {
                hoveredLayer = .genre
            } else if yearRange.contains(distance) {
                hoveredLayer = .year
            } else if consistencyRange.contains(distance) {
                hoveredLayer = .consistency
            } else {
                hoveredLayer = nil
            }

        case .ended:
            hoveredLayer = nil
        }
    }

    // MARK: - Animation

    private func animateDrawIn() {
        withAnimation(
            .spring(duration: 0.8, bounce: 0.15)
        ) {
            animatedGenre = genreCoverage
        }
        withAnimation(
            .spring(duration: 0.8, bounce: 0.15)
                .delay(0.05)
        ) {
            animatedYear = yearCoverage
        }
        withAnimation(
            .spring(duration: 0.8, bounce: 0.15)
                .delay(0.1)
        ) {
            animatedConsistency = consistencyCoverage
        }
    }

    // MARK: - Helpers

    private func maxRadius(for size: CGSize) -> CGFloat {
        min(size.width, size.height * 2) / 2
            - arcLineWidth / 2
    }

    private func coverage(for layer: GaugeLayer) -> Double {
        switch layer {
        case .genre: genreCoverage
        case .year: yearCoverage
        case .consistency: consistencyCoverage
        }
    }

    private var accessibilityDescription: String {
        "Genre \(Int(genreCoverage * 100)) percent, "
            + "Year \(Int(yearCoverage * 100)) percent, "
            + "Consistency \(Int(consistencyCoverage * 100)) percent, "
            + "\(trackCount) tracks"
    }
}

// MARK: - Equatable Conformance for GaugeLayer

extension GaugeLayer: Equatable {}

// MARK: - Preview

#Preview("HeroGauge — Filled") {
    HeroGauge(
        genreCoverage: 0.78,
        yearCoverage: 0.92,
        consistencyCoverage: 0.65,
        trackCount: 38085
    )
    .frame(width: 300, height: 200)
    .padding()
}

#Preview("HeroGauge — Empty") {
    HeroGauge(
        genreCoverage: 0.0,
        yearCoverage: 0.0,
        consistencyCoverage: 0.0,
        trackCount: 0
    )
    .frame(width: 300, height: 200)
    .padding()
}
