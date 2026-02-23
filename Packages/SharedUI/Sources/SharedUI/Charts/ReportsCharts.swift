// ReportsCharts.swift — Swift Charts for genre distribution and changes over time.

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
    public let changesOverTime: [DayCount]

    public init(
        totalProcessed: Int,
        genresUpdated: Int,
        yearsUpdated: Int,
        genreDistribution: [GenreCount],
        changesOverTime: [DayCount]
    ) {
        self.totalProcessed = totalProcessed
        self.genresUpdated = genresUpdated
        self.yearsUpdated = yearsUpdated
        self.genreDistribution = genreDistribution
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
/// and a line chart of changes over time.
///
/// Pure presentation component. Receives pre-aggregated `ChartSummaryData` and renders
/// using Swift Charts framework.
public struct ReportsCharts: View {
    public let data: ChartSummaryData

    public init(data: ChartSummaryData) {
        self.data = data
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                summaryCards
                genreDistributionChart
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
                title: "No Genre Data",
                description: "Genre distribution will appear after tracks are updated."
            )
            .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Genre Distribution")
                    .font(.headline)

                Chart(topGenres) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Genre", item.genre)
                    )
                    .foregroundStyle(Ayu.purple.gradient)
                    .clipShape(.rect(cornerRadius: 4))
                }
                .chartXAxisLabel("Tracks Updated")
                .frame(height: genreChartHeight)
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
                title: "No Timeline Data",
                description: "Change history will appear as tracks are updated over time."
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
    .frame(width: 600, height: 700)
}

#Preview("Reports Charts Empty") {
    ReportsCharts(data: ChartSummaryData(
        totalProcessed: 0,
        genresUpdated: 0,
        yearsUpdated: 0,
        genreDistribution: [],
        changesOverTime: []
    ))
    .frame(width: 600, height: 500)
}
