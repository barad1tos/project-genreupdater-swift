import Core
import Foundation
import Services
import SwiftData

struct DashboardMetricsSnapshotValues: Equatable {
    let totalTracks: Int
    let tracksWithGenre: Int
    let tracksWithYear: Int
    let tracksWithBoth: Int
    let tracksNeedingGenre: Int
    let tracksNeedingYear: Int
    let protectedFileCount: Int?
    let recentlyAdded: Int
    let timestamp: Date
}

func makeDashboardMetricsSnapshotValues(
    from loadedTracks: [Track],
    timestamp: Date = .now
) -> DashboardMetricsSnapshotValues? {
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

    return DashboardMetricsSnapshotValues(
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

func upsertDashboardMetricsSnapshot(
    from loadedTracks: [Track],
    in modelContext: ModelContext
) -> PersistedMetricsSnapshot? {
    guard let values = makeDashboardMetricsSnapshotValues(from: loadedTracks) else {
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
        let snapshot = PersistedMetricsSnapshot(
            totalTracks: values.totalTracks,
            tracksWithGenre: values.tracksWithGenre,
            tracksWithYear: values.tracksWithYear,
            tracksWithBoth: values.tracksWithBoth,
            tracksNeedingGenre: values.tracksNeedingGenre,
            tracksNeedingYear: values.tracksNeedingYear,
            protectedFileCount: values.protectedFileCount,
            recentlyAdded: values.recentlyAdded,
            timestamp: values.timestamp
        )
        modelContext.insert(snapshot)
    }

    try? modelContext.save()
    return try? modelContext.fetch(descriptor).first
}
