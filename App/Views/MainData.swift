import Core
import Services
import SharedUI
import SwiftData
import SwiftUI

struct SelectedUpdateScopeConfiguration {
    let tracks: [Track]
    let updateGenre: Bool
    let updateYear: Bool
    let previewOnly: Bool

    init(
        tracks: [Track],
        updateGenre: Bool,
        updateYear: Bool,
        previewOnly: Bool
    ) {
        self.tracks = tracks
        self.updateGenre = updateGenre
        self.updateYear = updateYear
        self.previewOnly = previewOnly
    }

    init(
        tracks: [Track],
        action: BrowseUpdateAction,
        defaultUpdateGenre: Bool,
        defaultUpdateYear: Bool,
        defaultPreviewOnly: Bool
    ) {
        switch action {
        case .genres:
            self.init(
                tracks: tracks,
                updateGenre: true,
                updateYear: false,
                previewOnly: defaultPreviewOnly
            )
        case .years:
            self.init(
                tracks: tracks,
                updateGenre: false,
                updateYear: true,
                previewOnly: defaultPreviewOnly
            )
        case .dryRun:
            self.init(
                tracks: tracks,
                updateGenre: defaultUpdateGenre,
                updateYear: defaultUpdateYear,
                previewOnly: true
            )
        }
    }

    @MainActor
    init(
        request: BrowseUpdateRequest,
        browseViewModel: BrowseViewModel,
        defaultUpdateGenre: Bool,
        defaultUpdateYear: Bool,
        defaultPreviewOnly: Bool
    ) {
        self.init(
            tracks: browseViewModel.tracksForUpdate(itemIDs: request.selectedItems),
            action: request.action,
            defaultUpdateGenre: defaultUpdateGenre,
            defaultUpdateYear: defaultUpdateYear,
            defaultPreviewOnly: defaultPreviewOnly
        )
    }
}

// Legacy workflow bridge retained until DesignUI owns equivalent browse/update flows.

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

    let total = loadedTracks.count
    var genreCount = 0
    var yearCount = 0
    var bothCount = 0
    var recentCount = 0
    let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: timestamp)
    let editabilitySummary = DashboardEditabilitySummary.make(from: loadedTracks)

    for track in loadedTracks {
        let hasGenre = GenreUtilities.hasPresentGenre(track.genre)
        let hasYear = track.year != nil

        if hasGenre {
            genreCount += 1
        }
        if hasYear {
            yearCount += 1
        }
        if hasGenre, hasYear {
            bothCount += 1
        }

        if let dateAdded = track.dateAdded,
           let cutoff = sevenDaysAgo,
           dateAdded >= cutoff {
            recentCount += 1
        }
    }

    return DashboardMetricsSnapshotValues(
        totalTracks: total,
        tracksWithGenre: genreCount,
        tracksWithYear: yearCount,
        tracksWithBoth: bothCount,
        tracksNeedingGenre: total - genreCount,
        tracksNeedingYear: total - yearCount,
        protectedFileCount: editabilitySummary.isProtectedFileCountKnown
            ? editabilitySummary.protectedFileCount
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
