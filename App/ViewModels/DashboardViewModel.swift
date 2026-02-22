// DashboardViewModel.swift — Library health calculation.

import Core
import Foundation
import Observation

// MARK: - Dashboard View Model

/// Computes library health metrics from a track collection.
///
/// Calculates fill percentages (genre, year), unique genre count,
/// and tracks needing attention. Metrics are computed synchronously
/// on refresh since the data is already in-memory.
@Observable @MainActor
final class DashboardViewModel {
    // MARK: - Metrics

    private(set) var totalTracks: Int = 0
    private(set) var genreFillPercent: Double = 0
    private(set) var yearFillPercent: Double = 0
    private(set) var uniqueGenres: Int = 0
    private(set) var uniqueArtists: Int = 0
    private(set) var tracksNeedingGenre: Int = 0
    private(set) var tracksNeedingYear: Int = 0
    private(set) var recentlyAdded: Int = 0
    private(set) var isLoading: Bool = false

    // MARK: - Top Genres

    private(set) var topGenres: [(name: String, count: Int)] = []

    // MARK: - Refresh

    /// Recompute all dashboard metrics from the given track array.
    ///
    /// This is intentionally synchronous — tracks are already loaded
    /// in memory by the parent view. Computation is O(n) over the
    /// track array with a single pass for most metrics.
    func refresh(tracks: [Track]) {
        isLoading = true
        defer { isLoading = false }

        let total = tracks.count
        totalTracks = total

        guard total > 0 else {
            resetMetrics()
            return
        }

        // Single-pass accumulation
        var genreCount = 0
        var yearCount = 0
        var genreSet = Set<String>()
        var artistSet = Set<String>()
        var genreFrequency: [String: Int] = [:]
        var recentCount = 0
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now)

        for track in tracks {
            // Genre metrics
            if let genre = track.genre, !genre.isEmpty {
                genreCount += 1
                genreSet.insert(genre)
                genreFrequency[genre, default: 0] += 1
            }

            // Year metrics
            if track.year != nil {
                yearCount += 1
            }

            // Artist count
            artistSet.insert(track.effectiveArtist)

            // Recently added (last 7 days)
            if let dateAdded = track.dateAdded,
               let cutoff = sevenDaysAgo,
               dateAdded >= cutoff {
                recentCount += 1
            }
        }

        genreFillPercent = Double(genreCount) / Double(total)
        yearFillPercent = Double(yearCount) / Double(total)
        uniqueGenres = genreSet.count
        uniqueArtists = artistSet.count
        tracksNeedingGenre = total - genreCount
        tracksNeedingYear = total - yearCount
        recentlyAdded = recentCount

        // Top 5 genres sorted by frequency
        topGenres = genreFrequency
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, count: $0.value) }
    }

    // MARK: - Private

    private func resetMetrics() {
        genreFillPercent = 0
        yearFillPercent = 0
        uniqueGenres = 0
        uniqueArtists = 0
        tracksNeedingGenre = 0
        tracksNeedingYear = 0
        recentlyAdded = 0
        topGenres = []
    }
}
