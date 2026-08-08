import Core
import Foundation
import SwiftData

/// Sendable currency of the metrics snapshot store: the persisted
/// @Model never crosses the store boundary.
public struct MetricsSnapshotValues: Equatable, Sendable {
    public let totalTracks: Int
    public let tracksWithGenre: Int
    public let tracksWithYear: Int
    public let tracksWithBoth: Int
    public let tracksNeedingGenre: Int
    public let tracksNeedingYear: Int
    public let protectedFileCount: Int?
    public let recentlyAdded: Int
    public let timestamp: Date
    public let previousTotalTracks: Int
    public let previousTracksNeedingGenre: Int
    public let previousTracksNeedingYear: Int
    public let previousRecentlyAdded: Int

    public init(
        totalTracks: Int,
        tracksWithGenre: Int,
        tracksWithYear: Int,
        tracksWithBoth: Int,
        tracksNeedingGenre: Int,
        tracksNeedingYear: Int,
        protectedFileCount: Int? = nil,
        recentlyAdded: Int,
        timestamp: Date,
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

    /// Counts freshly loaded tracks into snapshot values; nil for an
    /// empty library (nothing to persist). One counting formula: the
    /// numbers come from `ActivityHealthCounts` (D8), the writer only
    /// adds the 7-day recently-added window. `previous*` stays zero —
    /// the store rotates it from the persisted row on upsert.
    public static func make(from loadedTracks: [Core.Track], timestamp: Date = .now) -> Self? {
        guard !loadedTracks.isEmpty else { return nil }

        var recentCount = 0
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: timestamp)
        let healthCounts = ActivityHealthCounts.make(from: loadedTracks)

        for track in loadedTracks {
            if let dateAdded = track.dateAdded,
               let cutoff = sevenDaysAgo,
               dateAdded >= cutoff {
                recentCount += 1
            }
        }

        return Self(
            totalTracks: healthCounts.totalTracks,
            tracksWithGenre: healthCounts.tracksWithGenre,
            tracksWithYear: healthCounts.tracksWithYear,
            tracksWithBoth: healthCounts.tracksWithBoth,
            tracksNeedingGenre: healthCounts.totalTracks - healthCounts.tracksWithGenre,
            tracksNeedingYear: healthCounts.totalTracks - healthCounts.tracksWithYear,
            protectedFileCount: healthCounts.isProtectedFileCountKnown
                ? healthCounts.protectedFileCount
                : nil,
            recentlyAdded: recentCount,
            timestamp: timestamp
        )
    }
}

/// Owns every read and write of `PersistedMetricsSnapshot` (single-row
/// upsert semantics); the view layer never touches a model context for
/// metrics.
@ModelActor
public actor MetricsSnapshotStore {
    public func loadLatest() -> MetricsSnapshotValues? {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return makeValues(from: row)
    }

    /// Upserts values counted from a finished load; the previous scan's
    /// numbers rotate into the `previous*` trend baseline. Returns the
    /// persisted values (with the rotated baseline) or nil when the
    /// library was empty.
    @discardableResult
    public func upsert(from loadedTracks: [Core.Track], timestamp: Date = .now) -> MetricsSnapshotValues? {
        guard let values = MetricsSnapshotValues.make(from: loadedTracks, timestamp: timestamp) else {
            return nil
        }

        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        let existing = try? modelContext.fetch(descriptor).first

        if let snapshot = existing {
            snapshot.previousTotalTracks = snapshot.totalTracks
            snapshot.previousTracksNeedingGenre = snapshot.tracksNeedingGenre
            snapshot.previousTracksNeedingYear = snapshot.tracksNeedingYear
            snapshot.previousRecentlyAdded = snapshot.recentlyAdded

            snapshot.totalTracks = values.totalTracks
            snapshot.tracksWithGenre = values.tracksWithGenre
            snapshot.tracksWithYear = values.tracksWithYear
            snapshot.tracksWithBoth = values.tracksWithBoth
            snapshot.tracksNeedingGenre = values.tracksNeedingGenre
            snapshot.tracksNeedingYear = values.tracksNeedingYear
            snapshot.protectedFileCount = values.protectedFileCount
            snapshot.recentlyAdded = values.recentlyAdded
            snapshot.timestamp = values.timestamp
        } else {
            modelContext.insert(PersistedMetricsSnapshot(
                totalTracks: values.totalTracks,
                tracksWithGenre: values.tracksWithGenre,
                tracksWithYear: values.tracksWithYear,
                tracksWithBoth: values.tracksWithBoth,
                tracksNeedingGenre: values.tracksNeedingGenre,
                tracksNeedingYear: values.tracksNeedingYear,
                protectedFileCount: values.protectedFileCount,
                recentlyAdded: values.recentlyAdded,
                timestamp: values.timestamp
            ))
        }

        try? modelContext.save()
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return makeValues(from: row)
    }

    private func makeValues(from row: PersistedMetricsSnapshot) -> MetricsSnapshotValues {
        MetricsSnapshotValues(
            totalTracks: row.totalTracks,
            tracksWithGenre: row.tracksWithGenre,
            tracksWithYear: row.tracksWithYear,
            tracksWithBoth: row.tracksWithBoth,
            tracksNeedingGenre: row.tracksNeedingGenre,
            tracksNeedingYear: row.tracksNeedingYear,
            protectedFileCount: row.protectedFileCount,
            recentlyAdded: row.recentlyAdded,
            timestamp: row.timestamp,
            previousTotalTracks: row.previousTotalTracks,
            previousTracksNeedingGenre: row.previousTracksNeedingGenre,
            previousTracksNeedingYear: row.previousTracksNeedingYear,
            previousRecentlyAdded: row.previousRecentlyAdded
        )
    }
}
