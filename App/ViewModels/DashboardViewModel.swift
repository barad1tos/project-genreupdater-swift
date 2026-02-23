// DashboardViewModel.swift — Dashboard loading state machine with cached-first metrics and trends.

import Core
import Foundation
import Services
import SharedUI
import SwiftUI

// MARK: - Dashboard Loading State

/// Models the Dashboard's data lifecycle from first-launch shimmer through live data display.
enum DashboardLoadingState: Equatable, Sendable {
    /// First launch, no cache — show shimmer placeholders.
    case shimmer
    /// Showing cached data from a previous scan.
    case cached(lastUpdated: Date)
    /// Live scan in progress.
    case updating
    /// Showing live data from a completed scan.
    case live
    /// Scan failed with an error message.
    case error(String)
    /// MusicKit access denied by user.
    case permissionDenied
    /// Library has 0 tracks in Music.app.
    case emptyLibrary
}

// MARK: - Dashboard Metrics

/// Aggregated library health metrics for display.
struct DashboardMetrics: Equatable, Sendable {
    let totalTracks: Int
    let tracksWithGenre: Int
    let tracksWithYear: Int
    let tracksWithBoth: Int
    let tracksNeedingGenre: Int
    let tracksNeedingYear: Int
    let recentlyAdded: Int
    let genreCoverage: Double
    let yearCoverage: Double
    let consistencyCoverage: Double

    static let empty = Self(
        totalTracks: 0,
        tracksWithGenre: 0,
        tracksWithYear: 0,
        tracksWithBoth: 0,
        tracksNeedingGenre: 0,
        tracksNeedingYear: 0,
        recentlyAdded: 0,
        genreCoverage: 0,
        yearCoverage: 0,
        consistencyCoverage: 0
    )
}

// MARK: - Trend Direction

/// Directional trend indicator for metric cards.
enum TrendDirection: Sendable {
    case up
    case down
    case flat

    var icon: String {
        switch self {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        }
    }

    var tint: Color {
        switch self {
        case .up: Ayu.success
        case .down: Ayu.error
        case .flat: Ayu.fgSecondary
        }
    }
}

// MARK: - Dashboard View Model

/// Two-phase cached-first loading ViewModel with trend calculations.
///
/// On launch, loads cached metrics from `PersistedMetricsSnapshot` for
/// instant display, then refreshes from live MusicKit data. Computes
/// trend direction by comparing current metrics to previous scan values.
@Observable @MainActor
final class DashboardViewModel {
    // MARK: - Published State

    private(set) var loadingState: DashboardLoadingState = .shimmer
    private(set) var metrics: DashboardMetrics = .empty
    private(set) var previousMetrics: DashboardMetrics?

    // MARK: - Cached-First Loading

    /// Phase 1: Load cached metrics snapshot for instant display.
    ///
    /// If no snapshot exists (first launch), sets shimmer state.
    /// Otherwise builds metrics from the snapshot and loads previous
    /// scan values for trend calculation.
    func loadCachedMetrics(from snapshot: PersistedMetricsSnapshot?) {
        guard let snapshot else {
            loadingState = .shimmer
            return
        }

        metrics = DashboardMetrics(
            totalTracks: snapshot.totalTracks,
            tracksWithGenre: snapshot.tracksWithGenre,
            tracksWithYear: snapshot.tracksWithYear,
            tracksWithBoth: snapshot.tracksWithBoth,
            tracksNeedingGenre: snapshot.tracksNeedingGenre,
            tracksNeedingYear: snapshot.tracksNeedingYear,
            recentlyAdded: snapshot.recentlyAdded,
            genreCoverage: snapshot.genreCoverage,
            yearCoverage: snapshot.yearCoverage,
            consistencyCoverage: snapshot.consistencyCoverage
        )

        // Build previous metrics from snapshot's stored baseline
        if snapshot.previousTotalTracks > 0 {
            previousMetrics = DashboardMetrics(
                totalTracks: snapshot.previousTotalTracks,
                tracksWithGenre: 0,
                tracksWithYear: 0,
                tracksWithBoth: 0,
                tracksNeedingGenre: snapshot.previousTracksNeedingGenre,
                tracksNeedingYear: snapshot.previousTracksNeedingYear,
                recentlyAdded: snapshot.previousRecentlyAdded,
                genreCoverage: 0,
                yearCoverage: 0,
                consistencyCoverage: 0
            )
        }

        loadingState = .cached(lastUpdated: snapshot.timestamp)
    }

    /// Phase 2: Refresh metrics from live MusicKit track data.
    ///
    /// Computes all metrics in a single O(n) pass. Saves current metrics
    /// as previous for trend calculation if they contain real data.
    func refreshFromLive(tracks: [Track]) {
        guard !tracks.isEmpty else {
            loadingState = .emptyLibrary
            return
        }

        // Save current as previous if it has real data
        if metrics.totalTracks > 0 {
            previousMetrics = metrics
        }

        let total = tracks.count
        var genreCount = 0
        var yearCount = 0
        var bothCount = 0
        var recentCount = 0
        let sevenDaysAgo = Calendar.current.date(
            byAdding: .day,
            value: -7,
            to: .now
        )

        // Single-pass accumulation
        for track in tracks {
            let hasGenre = track.genre.map { !$0.isEmpty } ?? false
            let hasYear = track.year != nil

            if hasGenre { genreCount += 1 }
            if hasYear { yearCount += 1 }
            if hasGenre, hasYear { bothCount += 1 }

            if let dateAdded = track.dateAdded,
               let cutoff = sevenDaysAgo,
               dateAdded >= cutoff {
                recentCount += 1
            }
        }

        metrics = DashboardMetrics(
            totalTracks: total,
            tracksWithGenre: genreCount,
            tracksWithYear: yearCount,
            tracksWithBoth: bothCount,
            tracksNeedingGenre: total - genreCount,
            tracksNeedingYear: total - yearCount,
            recentlyAdded: recentCount,
            genreCoverage: Double(genreCount) / Double(total),
            yearCoverage: Double(yearCount) / Double(total),
            consistencyCoverage: Double(bothCount) / Double(total)
        )

        loadingState = .live
    }

    /// Set the permission denied state.
    func setPermissionDenied() {
        loadingState = .permissionDenied
    }

    /// Set the error state with a message.
    func setError(_ message: String) {
        loadingState = .error(message)
    }

    // MARK: - Trend Calculations

    /// Genre trend: fewer tracks needing genre is good (down).
    var genreTrend: TrendDirection? {
        guard let previous = previousMetrics else { return nil }
        return trendForDecreasing(
            current: metrics.tracksNeedingGenre,
            previous: previous.tracksNeedingGenre
        )
    }

    /// Year trend: fewer tracks needing year is good (down).
    var yearTrend: TrendDirection? {
        guard let previous = previousMetrics else { return nil }
        return trendForDecreasing(
            current: metrics.tracksNeedingYear,
            previous: previous.tracksNeedingYear
        )
    }

    /// Recently added trend: more is neutral/positive (up).
    var recentTrend: TrendDirection? {
        guard let previous = previousMetrics else { return nil }
        let current = metrics.recentlyAdded
        let prev = previous.recentlyAdded
        if current > prev { return .up }
        if current < prev { return .down }
        return .flat
    }

    /// Delta for genre trend (positive = more needing, negative = fewer needing).
    var genreTrendDelta: Int? {
        guard let previous = previousMetrics else { return nil }
        return metrics.tracksNeedingGenre - previous.tracksNeedingGenre
    }

    /// Delta for year trend.
    var yearTrendDelta: Int? {
        guard let previous = previousMetrics else { return nil }
        return metrics.tracksNeedingYear - previous.tracksNeedingYear
    }

    /// Delta for recently added trend.
    var recentTrendDelta: Int? {
        guard let previous = previousMetrics else { return nil }
        return metrics.recentlyAdded - previous.recentlyAdded
    }

    // MARK: - Private

    /// Trend for metrics where decrease is good (fewer tracks needing attention).
    private func trendForDecreasing(current: Int, previous: Int) -> TrendDirection {
        if current < previous { return .down }
        if current > previous { return .up }
        return .flat
    }
}
