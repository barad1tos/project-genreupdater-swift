// ReportsCharts.swift — Swift Charts for genre distribution, year histogram, and changes over time.

import Charts
import Core
import SwiftUI

// MARK: - Chart Summary Data

/// Aggregated data model for the reports charts view.
///
/// Decouples chart presentation from raw `ChangeLogEntry` arrays so the
/// SharedUI package stays a pure presentation layer.
public struct ChartSummaryData: Sendable {
    public let totalProcessed: Int
    public let genresUpdated: Int
    public let yearsUpdated: Int
    public let genreDistribution: [GenreCount]
    public let yearDistribution: [YearCount]
    public let changesOverTime: [DayCount]

    public init(
        totalProcessed: Int,
        genresUpdated: Int,
        yearsUpdated: Int,
        genreDistribution: [GenreCount],
        yearDistribution: [YearCount] = [],
        changesOverTime: [DayCount]
    ) {
        self.totalProcessed = totalProcessed
        self.genresUpdated = genresUpdated
        self.yearsUpdated = yearsUpdated
        self.genreDistribution = genreDistribution
        self.yearDistribution = yearDistribution
        self.changesOverTime = changesOverTime
    }

    /// A genre name paired with its occurrence count.
    public struct GenreCount: Identifiable, Sendable {
        public let id: String
        public let genre: String
        public let count: Int

        public init(genre: String, count: Int) {
            id = genre
            self.genre = genre
            self.count = count
        }
    }

    /// A release year paired with the number of tracks for that year.
    public struct YearCount: Identifiable, Sendable {
        public let id: Int
        public let year: Int
        public let count: Int

        public init(year: Int, count: Int) {
            id = year
            self.year = year
            self.count = count
        }
    }

    /// A date paired with the number of changes on that day.
    public struct DayCount: Identifiable, Sendable {
        public let id: Date
        public let date: Date
        public let count: Int

        public init(date: Date, count: Int) {
            id = date
            self.date = date
            self.count = count
        }
    }
}

// MARK: - Reports Charts

/// Dashboard-style charts view showing summary cards, genre distribution bar chart,
/// year distribution histogram, and a line chart of changes over time.
///
/// Pure presentation component. Receives pre-aggregated `ChartSummaryData` and renders
/// using Swift Charts framework. Chart bars animate from zero on first render using
/// `springOrganic`, and hovering a bar shows a tooltip with the exact count.
public struct ReportsCharts: View {
    public let data: ChartSummaryData

    @State private var genreChartAnimated = false
    @State private var yearChartAnimated = false
    @State private var hoveredGenre: String?
    @State private var hoveredYear: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionScale) private var motionScale

    public init(data: ChartSummaryData) {
        self.data = data
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                summaryCards
                genreDistributionChart
                yearDistributionChart
                changesOverTimeChart
            }
            .padding()
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: Spacing.md) {
            SummaryCard(
                title: "Total Processed",
                value: data.totalProcessed,
                icon: "music.note.list",
                tint: Ayu.info
            )

            SummaryCard(
                title: "Genres Updated",
                value: data.genresUpdated,
                icon: "tag.fill",
                tint: Ayu.purple
            )

            SummaryCard(
                title: "Years Updated",
                value: data.yearsUpdated,
                icon: "calendar",
                tint: Ayu.accent
            )
        }
    }

    // MARK: - Genre Distribution Chart

    @ViewBuilder
    private var genreDistributionChart: some View {
        if data.genreDistribution.isEmpty {
            EmptyStateView(
                icon: "chart.bar",
                title: "Genre insights appear after your first update",
                description: "Update your library to see which genres are most common."
            )
            .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Genre Distribution")
                    .font(.headline)

                Chart(topGenres) { item in
                    BarMark(
                        x: .value("Count", genreChartAnimated ? item.count : 0),
                        y: .value("Genre", item.genre)
                    )
                    .foregroundStyle(Ayu.purple.gradient)
                    .clipShape(.rect(cornerRadius: 4))
                    .opacity(hoveredGenre == nil || hoveredGenre == item.genre ? 1.0 : 0.3)
                    .annotation(position: .trailing, spacing: 4) {
                        if hoveredGenre == item.genre {
                            Text("\(item.count)")
                                .font(AppFont.caption)
                                .foregroundStyle(Ayu.fgPrimary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxs)
                                .background(Ayu.bgSecondary, in: .capsule)
                                .ayuShadow(Shadow.medium)
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(.rect)
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    hoveredGenre = proxy.value(atY: location.y) as String?
                                case .ended:
                                    hoveredGenre = nil
                                }
                            }
                    }
                }
                .chartXAxisLabel("Tracks Updated")
                .frame(height: genreChartHeight)
                .onAppear {
                    guard !genreChartAnimated else { return }
                    if reduceMotion {
                        genreChartAnimated = true
                        return
                    }
                    withAnimation(Motion.scaled(Motion.springOrganic, by: motionScale)) {
                        genreChartAnimated = true
                    }
                }
            }
            .padding()
            .background(Ayu.bgSecondary.opacity(0.5), in: .rect(cornerRadius: Radius.md))
        }
    }

    // MARK: - Year Distribution Chart

    @ViewBuilder
    private var yearDistributionChart: some View {
        if data.yearDistribution.isEmpty {
            EmptyStateView(
                icon: "calendar.badge.clock",
                title: "Year insights appear after your first update",
                description: "Track release years will be visualized here after updates."
            )
            .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Year Distribution")
                    .font(.headline)

                Chart(sortedYears) { item in
                    BarMark(
                        x: .value("Year", String(item.year)),
                        y: .value("Tracks", yearChartAnimated ? item.count : 0)
                    )
                    .foregroundStyle(Ayu.accent.gradient)
                    .clipShape(.rect(cornerRadius: 4))
                    .opacity(hoveredYear == nil || hoveredYear == String(item.year) ? 1.0 : 0.3)
                    .annotation(position: .top, spacing: 4) {
                        if hoveredYear == String(item.year) {
                            Text("\(item.count)")
                                .font(AppFont.caption)
                                .foregroundStyle(Ayu.fgPrimary)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxs)
                                .background(Ayu.bgSecondary, in: .capsule)
                                .ayuShadow(Shadow.medium)
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(.rect)
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    hoveredYear = proxy.value(atX: location.x) as String?
                                case .ended:
                                    hoveredYear = nil
                                }
                            }
                    }
                }
                .chartYAxisLabel("Tracks")
                .frame(height: 200)
                .onAppear {
                    guard !yearChartAnimated else { return }
                    if reduceMotion {
                        yearChartAnimated = true
                        return
                    }
                    withAnimation(Motion.scaled(Motion.springOrganic, by: motionScale)) {
                        yearChartAnimated = true
                    }
                }
            }
            .padding()
            .background(Ayu.bgSecondary.opacity(0.5), in: .rect(cornerRadius: Radius.md))
        }
    }

    // MARK: - Changes Over Time Chart

    @ViewBuilder
    private var changesOverTimeChart: some View {
        if data.changesOverTime.isEmpty {
            EmptyStateView(
                icon: "chart.line.uptrend.xyaxis",
                title: "Timeline data builds as you update tracks over time",
                description: "Each update session adds data points to this chart."
            )
            .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Changes Over Time")
                    .font(.headline)

                Chart(data.changesOverTime) { item in
                    LineMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("Changes", item.count)
                    )
                    .foregroundStyle(Ayu.info.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("Changes", item.count)
                    )
                    .foregroundStyle(Ayu.info.opacity(0.1).gradient)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("Changes", item.count)
                    )
                    .foregroundStyle(Ayu.info)
                    .symbolSize(30)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxisLabel("Changes")
                .frame(height: 200)
            }
            .padding()
            .background(Ayu.bgSecondary.opacity(0.5), in: .rect(cornerRadius: Radius.md))
        }
    }

    // MARK: - Private Helpers

    /// Show at most 15 genres in the bar chart, sorted by count descending.
    private var topGenres: [ChartSummaryData.GenreCount] {
        Array(
            data.genreDistribution
                .sorted { $0.count > $1.count }
                .prefix(15)
        )
    }

    /// Year distribution sorted by year ascending for chronological display.
    private var sortedYears: [ChartSummaryData.YearCount] {
        data.yearDistribution.sorted { $0.year < $1.year }
    }

    /// Dynamic chart height based on the number of genres displayed.
    private var genreChartHeight: CGFloat {
        CGFloat(max(topGenres.count, 3)) * 28
    }
}

// MARK: - Summary Card

/// Single metric card showing a titled value with icon and tint color.
struct SummaryCard: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(value, format: .number)
                .font(.system(.title, design: .rounded))
                .bold()
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Ayu.bgSecondary.opacity(0.5), in: .rect(cornerRadius: Radius.md))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Preview

#Preview("Reports Charts") {
    ReportsCharts(data: ChartSummaryData(
        totalProcessed: 1247,
        genresUpdated: 892,
        yearsUpdated: 355,
        genreDistribution: [
            .init(genre: "Metal", count: 234),
            .init(genre: "Electronic", count: 189),
            .init(genre: "Rock", count: 156),
            .init(genre: "Pop", count: 98),
            .init(genre: "Jazz", count: 67),
            .init(genre: "Hip-Hop", count: 54),
            .init(genre: "Classical", count: 42),
            .init(genre: "R&B", count: 33),
        ],
        yearDistribution: [
            .init(year: 1970, count: 12),
            .init(year: 1980, count: 45),
            .init(year: 1990, count: 128),
            .init(year: 2000, count: 267),
            .init(year: 2010, count: 312),
            .init(year: 2020, count: 189),
        ],
        changesOverTime: [
            .init(date: .now.addingTimeInterval(-6 * 86400), count: 45),
            .init(date: .now.addingTimeInterval(-5 * 86400), count: 120),
            .init(date: .now.addingTimeInterval(-4 * 86400), count: 89),
            .init(date: .now.addingTimeInterval(-3 * 86400), count: 210),
            .init(date: .now.addingTimeInterval(-2 * 86400), count: 156),
            .init(date: .now.addingTimeInterval(-1 * 86400), count: 178),
            .init(date: .now, count: 94),
        ]
    ))
    .frame(width: 600, height: 900)
}

#Preview("Reports Charts Empty") {
    ReportsCharts(data: ChartSummaryData(
        totalProcessed: 0,
        genresUpdated: 0,
        yearsUpdated: 0,
        genreDistribution: [],
        changesOverTime: []
    ))
    .frame(width: 600, height: 700)
}
