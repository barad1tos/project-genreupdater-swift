// GaugeView.swift — Multi-ring gauge showing library health metrics.

import SharedUI
import SwiftUI

// MARK: - GaugeView

/// Two concentric arc rings showing genre fill and year fill percentages,
/// with a centered total track count.
///
/// The outer ring represents genre coverage (Ayu.purple) and the inner ring
/// represents year coverage (Ayu.info). Both rings animate on appear with
/// a spring curve for a polished entrance.
struct GaugeView: View {
    let totalTracks: Int
    let genreFillPercent: Double
    let yearFillPercent: Double
    var size: CGFloat = 200

    @State private var animatedGenre: Double = 0
    @State private var animatedYear: Double = 0

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ZStack {
                outerTrack
                outerArc
                innerTrack
                innerArc
                centerLabel
            }
            .frame(width: size, height: size)

            legend
        }
        .onAppear {
            withAnimation(.spring(duration: 1.0, bounce: 0.3)) {
                animatedGenre = clampedGenre
                animatedYear = clampedYear
            }
        }
        .onChange(of: genreFillPercent) {
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                animatedGenre = clampedGenre
            }
        }
        .onChange(of: yearFillPercent) {
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                animatedYear = clampedYear
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Library health gauge")
        .accessibilityValue(
            "\(totalTracks) tracks, "
                + "\(Int(clampedGenre * 100)) percent have genres, "
                + "\(Int(clampedYear * 100)) percent have years"
        )
    }

    // MARK: - Outer Ring (Genre)

    private var outerTrack: some View {
        Circle()
            .stroke(Ayu.purple.opacity(0.15), lineWidth: outerLineWidth)
            .padding(outerLineWidth / 2)
    }

    private var outerArc: some View {
        Circle()
            .trim(from: 0, to: animatedGenre)
            .stroke(
                genreGradient,
                style: StrokeStyle(lineWidth: outerLineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .padding(outerLineWidth / 2)
    }

    // MARK: - Inner Ring (Year)

    private var innerTrack: some View {
        Circle()
            .stroke(Ayu.info.opacity(0.15), lineWidth: innerLineWidth)
            .padding(outerLineWidth + innerGap + innerLineWidth / 2)
    }

    private var innerArc: some View {
        Circle()
            .trim(from: 0, to: animatedYear)
            .stroke(
                yearGradient,
                style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .padding(outerLineWidth + innerGap + innerLineWidth / 2)
    }

    // MARK: - Center

    private var centerLabel: some View {
        VStack(spacing: 0) {
            Text(totalTracks.formatted())
                .font(centerFont)
                .foregroundStyle(Ayu.fgPrimary)
                .contentTransition(.numericText())
            Text("tracks")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Spacing.md) {
            legendItem(
                color: Ayu.purple,
                label: "Genre",
                percent: clampedGenre
            )
            legendItem(
                color: Ayu.info,
                label: "Year",
                percent: clampedYear
            )
        }
    }

    private func legendItem(color: Color, label: String, percent: Double) -> some View {
        HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(Int(percent * 100))%")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    // MARK: - Sizing

    private var outerLineWidth: CGFloat {
        size * 0.07
    }

    private var innerLineWidth: CGFloat {
        size * 0.06
    }

    private var innerGap: CGFloat {
        size * 0.03
    }

    private var centerFont: Font {
        size >= 200 ? AppFont.display : AppFont.metric
    }

    // MARK: - Clamped Values

    private var clampedGenre: Double {
        min(max(genreFillPercent, 0), 1)
    }

    private var clampedYear: Double {
        min(max(yearFillPercent, 0), 1)
    }

    // MARK: - Gradients

    private var genreGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [Ayu.purple, Ayu.purple.opacity(0.7)]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360 * animatedGenre)
        )
    }

    private var yearGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [Ayu.info, Ayu.info.opacity(0.7)]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360 * animatedYear)
        )
    }
}

// MARK: - Preview

#Preview("Gauge View — Large") {
    GaugeView(
        totalTracks: 38247,
        genreFillPercent: 0.72,
        yearFillPercent: 0.58,
        size: 220
    )
    .padding()
}

#Preview("Gauge View — Small") {
    GaugeView(
        totalTracks: 1200,
        genreFillPercent: 0.95,
        yearFillPercent: 0.40,
        size: 120
    )
    .padding()
}
