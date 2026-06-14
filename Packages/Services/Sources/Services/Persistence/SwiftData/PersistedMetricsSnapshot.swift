// PersistedMetricsSnapshot.swift — Cached dashboard metrics for instant-load.

import Foundation
import SwiftData

/// Cached aggregate dashboard metrics for instant-load on launch.
///
/// This is a single-row model (always upsert, not append). Stores the latest
/// scan metrics plus the previous scan's values for trend calculation, avoiding
/// a history table.
@Model
public final class PersistedMetricsSnapshot {
    public var totalTracks: Int
    public var tracksWithGenre: Int
    public var tracksWithYear: Int
    public var tracksWithBoth: Int
    public var tracksNeedingGenre: Int
    public var tracksNeedingYear: Int
    public var protectedFileCount: Int?
    public var recentlyAdded: Int
    public var timestamp: Date

    // Trend baseline — stores the prior scan's values
    public var previousTotalTracks: Int
    public var previousTracksNeedingGenre: Int
    public var previousTracksNeedingYear: Int
    public var previousRecentlyAdded: Int

    public init(
        totalTracks: Int,
        tracksWithGenre: Int,
        tracksWithYear: Int,
        tracksWithBoth: Int,
        tracksNeedingGenre: Int,
        tracksNeedingYear: Int,
        protectedFileCount: Int? = nil,
        recentlyAdded: Int,
        timestamp: Date = .now,
        previousTotalTracks: Int = 0,
        previousTracksNeedingGenre: Int = 0,
        previousTracksNeedingYear: Int = 0,
        previousRecentlyAdded: Int = 0
    ) {
        self.totalTracks = totalTracks
        self.tracksWithGenre = tracksWithGenre
        self.tracksWithYear = tracksWithYear
        self.tracksWithBoth = tracksWithBoth
        self.tracksNeedingGenre = tracksNeedingGenre
        self.tracksNeedingYear = tracksNeedingYear
        self.protectedFileCount = protectedFileCount
        self.recentlyAdded = recentlyAdded
        self.timestamp = timestamp
        self.previousTotalTracks = previousTotalTracks
        self.previousTracksNeedingGenre = previousTracksNeedingGenre
        self.previousTracksNeedingYear = previousTracksNeedingYear
        self.previousRecentlyAdded = previousRecentlyAdded
    }

    // MARK: - Computed Coverages

    /// Genre coverage as a ratio (0.0 to 1.0).
    public var genreCoverage: Double {
        totalTracks > 0 ? Double(tracksWithGenre) / Double(totalTracks) : 0
    }

    /// Year coverage as a ratio (0.0 to 1.0).
    public var yearCoverage: Double {
        totalTracks > 0 ? Double(tracksWithYear) / Double(totalTracks) : 0
    }

    /// Consistency coverage — tracks with BOTH genre AND year filled.
    public var consistencyCoverage: Double {
        totalTracks > 0 ? Double(tracksWithBoth) / Double(totalTracks) : 0
    }
}
