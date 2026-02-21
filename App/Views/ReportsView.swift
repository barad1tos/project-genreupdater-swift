// ReportsView.swift — Container composing change log and charts from SwiftData.
//
// Uses @Query to fetch PersistedChangeLogEntry from SwiftData, converts to
// Core.ChangeLogEntry for the SharedUI presentation components.
// Change log is available on free tier; charts are gated behind .reportsCharts.

import Core
import Services
import SharedUI
import SwiftData
import SwiftUI

// MARK: - Reports View

/// Reports dashboard combining a change log table and summary charts.
///
/// The change log (`ReportsChangeLog`) is always visible (free tier feature).
/// The charts section (`ReportsCharts`) requires Week Pass or higher and is
/// wrapped in `FeatureGatedView`.
struct ReportsView: View {
    @Query(sort: \PersistedChangeLogEntry.timestamp, order: .reverse)
    private var persistedEntries: [PersistedChangeLogEntry]

    var body: some View {
        let entries = persistedEntries.map { $0.toChangeLogEntry() }

        VSplitView {
            ReportsChangeLog(entries: entries)
                .frame(minHeight: 200)

            FeatureGatedView(feature: .reportsCharts) {
                ReportsCharts(data: aggregateData(from: entries))
            }
            .frame(minHeight: 250)
        }
        .navigationTitle("Reports")
    }

    // MARK: - Data Aggregation

    /// Build chart summary data from change log entries.
    ///
    /// Groups entries by type and date to produce genre distribution and
    /// daily change counts for the charts view.
    private func aggregateData(from entries: [ChangeLogEntry]) -> ChartSummaryData {
        let genreEntries = entries.filter { $0.changeType == .genreUpdate }
        let yearEntries = entries.filter { $0.changeType == .yearUpdate || $0.changeType == .yearRevert }

        let genreDistribution = buildGenreDistribution(from: genreEntries)
        let changesOverTime = buildChangesOverTime(from: entries)

        return ChartSummaryData(
            totalProcessed: entries.count,
            genresUpdated: genreEntries.count,
            yearsUpdated: yearEntries.count,
            genreDistribution: genreDistribution,
            changesOverTime: changesOverTime
        )
    }

    /// Count occurrences of each new genre across genre update entries.
    private func buildGenreDistribution(
        from entries: [ChangeLogEntry]
    ) -> [ChartSummaryData.GenreCount] {
        var genreCounts: [String: Int] = [:]
        for entry in entries {
            if let genre = entry.newGenre, !genre.isEmpty {
                genreCounts[genre, default: 0] += 1
            }
        }
        return genreCounts.map { ChartSummaryData.GenreCount(genre: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Group entries by calendar day and count changes per day.
    private func buildChangesOverTime(
        from entries: [ChangeLogEntry]
    ) -> [ChartSummaryData.DayCount] {
        let calendar = Calendar.current
        var dayCounts: [Date: Int] = [:]

        for entry in entries {
            let dayStart = calendar.startOfDay(for: entry.timestamp)
            dayCounts[dayStart, default: 0] += 1
        }

        return dayCounts.map { ChartSummaryData.DayCount(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
    }
}
