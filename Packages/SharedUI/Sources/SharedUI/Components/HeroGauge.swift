// HeroGauge.swift — Half-circle stacked arc gauge with per-arc hover and click navigation.

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
public enum GaugeLayer: CaseIterable, Sendable, Equatable {
    case genre
    case year
    case consistency

    /// Arc color per CONTEXT.md spec.
    public var color: Color {
        switch self {
        case .genre: Ayu.purple
        case .year: Ayu.info
        case .consistency: Ayu.accent
        }
    }

    /// Human-readable label for this layer.
    public var label: String {
        switch self {
        case .genre: "Genre"
        case .year: "Year"
        case .consistency: "Consistency"
        }
    }
}

// MARK: - HeroGauge

/// Dashboard hero gauge showing library health as three stacked half-circle arcs.
///
/// Displays genre, year, and consistency coverage as stacked arcs at close radii
/// with subtle shadow between layers for a layered depth effect. Supports per-arc
/// hover to show layer details and click navigation via `onArcTapped`.
///
/// Accepts only plain types -- no Core model dependency.
public struct HeroGauge: View {
    private let genreCoverage: Double
    private let yearCoverage: Double
    private let consistencyCoverage: Double
    private let trackCount: Int
    private let onArcTapped: ((GaugeLayer) -> Void)?
    private let detailedCounts: DetailedCounts?

    @State private var animatedGenre: Double = 0
    @State private var animatedYear: Double = 0
    @State private var animatedConsistency: Double = 0
    @State private var hoveredLayer: GaugeLayer?

    private let arcLineWidth: CGFloat = 16
    private let arcGap: CGFloat = 2

    /// Detailed count data for extended hover information.
    public struct DetailedCounts: Sendable {
        /// Genre counts: (tagged, total).
        public let genre: (tagged: Int, total: Int)
        /// Year counts: (tagged, total).
        public let year: (tagged: Int, total: Int)
        /// Consistency counts: (tagged, total).
        public let consistency: (tagged: Int, total: Int)

        public init(
            genre: (tagged: Int, total: Int),
            year: (tagged: Int, total: Int),
            consistency: (tagged: Int, total: Int)
        ) {
            self.genre = genre
            self.year = year
            self.consistency = consistency
        }
    }

    public init(
        genreCoverage: Double,
        yearCoverage: Double,
        consistencyCoverage: Double,
        trackCount: Int,
        onArcTapped: ((GaugeLayer) -> Void)? = nil,
        detailedCounts: DetailedCounts? = nil
    ) {
        self.genreCoverage = genreCoverage
        self.yearCoverage = yearCoverage
        self.consistencyCoverage = consistencyCoverage
        self.trackCount = trackCount
        self.onArcTapped = onArcTapped
        self.detailedCounts = detailedCounts
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
            .contentShape(.rect)
            .onContinuousHover { phase in
                handleHover(
                    phase,
                    in: geometry.size,
                    maxRadius: maxRadius
                )
            }
            .onTapGesture { location in
                handleTap(
                    at: location,
                    in: geometry.size,
                    maxRadius: maxRadius
                )
            }
        }
        .onAppear {
            animatedGenre = genreCoverage
            animatedYear = yearCoverage
            animatedConsistency = consistencyCoverage
        }
        .onChange(of: genreCoverage) { _, newValue in
            animatedGenre = newValue
        }
        .onChange(of: yearCoverage) { _, newValue in
            animatedYear = newValue
        }
        .onChange(of: consistencyCoverage) { _, newValue in
            animatedConsistency = newValue
        }
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

            // Value arc with shadow for layered depth
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
            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
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

                if let counts = detailedCounts {
                    let pair = detailPair(for: layer, counts: counts)
                    Text("\(pair.tagged.formatted()) of \(pair.total.formatted()) tagged")
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgMuted)
                }
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
            hoveredLayer = detectLayer(
                at: location,
                in: size,
                maxRadius: maxRadius
            )

        case .ended:
            hoveredLayer = nil
        }
    }

    // MARK: - Tap Detection

    private func handleTap(
        at location: CGPoint,
        in size: CGSize,
        maxRadius: CGFloat
    ) {
        guard let callback = onArcTapped else { return }
        if let layer = detectLayer(at: location, in: size, maxRadius: maxRadius) {
            callback(layer)
        }
    }

    /// Shared ring detection logic for hover and tap.
    private func detectLayer(
        at location: CGPoint,
        in size: CGSize,
        maxRadius: CGFloat
    ) -> GaugeLayer? {
        let center = CGPoint(
            x: size.width / 2,
            y: size.height
        )
        let deltaX = location.x - center.x
        let deltaY = location.y - center.y

        // Only detect in upper half (arcs open upward)
        guard deltaY <= 0 else { return nil }

        let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
        let halfWidth = arcLineWidth / 2

        let genreRadius = maxRadius
        let yearRadius = maxRadius - arcLineWidth - arcGap
        let consistencyRadius = maxRadius - 2 * (arcLineWidth + arcGap)

        let genreRange = (genreRadius - halfWidth) ... (genreRadius + halfWidth)
        let yearRange = (yearRadius - halfWidth) ... (yearRadius + halfWidth)
        let consistencyRange = (consistencyRadius - halfWidth) ... (consistencyRadius + halfWidth)

        if genreRange.contains(distance) {
            return .genre
        } else if yearRange.contains(distance) {
            return .year
        } else if consistencyRange.contains(distance) {
            return .consistency
        }
        return nil
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

    private func detailPair(
        for layer: GaugeLayer,
        counts: DetailedCounts
    ) -> (tagged: Int, total: Int) {
        switch layer {
        case .genre: counts.genre
        case .year: counts.year
        case .consistency: counts.consistency
        }
    }

    private var accessibilityDescription: String {
        "Genre \(Int(genreCoverage * 100)) percent, "
            + "Year \(Int(yearCoverage * 100)) percent, "
            + "Consistency \(Int(consistencyCoverage * 100)) percent, "
            + "\(trackCount) tracks"
    }
}

// MARK: - Preview

#Preview("HeroGauge -- Filled") {
    HeroGauge(
        genreCoverage: 0.78,
        yearCoverage: 0.92,
        consistencyCoverage: 0.65,
        trackCount: 38085,
        detailedCounts: .init(
            genre: (tagged: 29706, total: 38085),
            year: (tagged: 35038, total: 38085),
            consistency: (tagged: 24755, total: 38085)
        )
    )
    .frame(width: 300, height: 200)
    .padding()
}

#Preview("HeroGauge -- Empty") {
    HeroGauge(
        genreCoverage: 0.0,
        yearCoverage: 0.0,
        consistencyCoverage: 0.0,
        trackCount: 0
    )
    .frame(width: 300, height: 200)
    .padding()
}
