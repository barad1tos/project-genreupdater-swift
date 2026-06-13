// MainView+Data.swift -- library loading, workflow defaults, and metrics snapshots.

import Core
import Services
import SharedUI
import SwiftData
import SwiftUI

extension MainView {
    func updateColumnVisibility() {
        let needsDetail = selectedCategory == .browse && browseViewModel.selectedAlbum != nil
        let target: NavigationSplitViewVisibility = needsDetail ? .all : .doubleColumn
        if columnVisibility != target {
            withAnimation(Motion.curveLayout) {
                columnVisibility = target
            }
        }
    }

    func loadTracks(forceRefresh: Bool = false) async {
        libraryLoadError = nil
        loadCachedSnapshot()
        ensureWorkflowViewModel()

        guard let reader = dependencies.musicReader else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loadStart = ContinuousClock.now
            if !forceRefresh, let cachedTracks = await dependencies.loadLibrarySnapshot() {
                tracks = cachedTracks
                browseViewModel.tracks = cachedTracks
                lastLibraryScanDate = .now
                saveMetricsSnapshot(from: cachedTracks)
                await recordLibraryLoad(source: "snapshot", count: cachedTracks.count, startedAt: loadStart)
                return
            }

            try await reader.requestAuthorization()
            tracks = try await reader.fetchAllTracks()
            await dependencies.refreshTrackIDMapping(musicKitTracks: tracks)
            await dependencies.persistLoadedLibraryTracks(tracks)
            browseViewModel.tracks = tracks
            lastLibraryScanDate = .now
            saveMetricsSnapshot(from: tracks)
            await recordLibraryLoad(source: "music", count: tracks.count, startedAt: loadStart)
        } catch {
            await dependencies.analyticsService?.trackError("library.load", error: error)
            libraryLoadError = libraryLoadError(from: error)
            tracks = []
            browseViewModel.tracks = []
        }
    }

    func ensureWorkflowViewModel() {
        guard workflowViewModel == nil,
              let coordinator = dependencies.updateCoordinator,
              let pipeline = dependencies.changePreviewPipeline,
              let processor = dependencies.batchProcessor
        else { return }

        workflowViewModel = WorkflowViewModel(
            updateCoordinator: coordinator,
            batchProcessor: processor,
            changePreviewPipeline: pipeline,
            pendingVerificationService: dependencies.pendingVerificationService,
            featureGate: dependencies.featureGate,
            recordProcessedTracks: { count in
                dependencies.subscriptionService?.incrementFreeTracksUsed(by: count)
            },
            runMaintenancePreflight: {
                await dependencies.runMaintenancePreflight()
            },
            defaultUpdateGenre: configuredUpdateSelection.updateGenre,
            defaultUpdateYear: configuredUpdateSelection.updateYear,
            defaultPreviewOnly: configuredPreviewOnly,
            defaultMinConfidence: configuredMinConfidence,
            defaultReleaseYearRestoreThreshold: dependencies.config.processing.releaseYearRestoreThreshold
        )
    }

    var configuredUpdateSelection: (updateGenre: Bool, updateYear: Bool) {
        switch UpdateBehavior(rawValue: defaultUpdateBehavior) ?? .both {
        case .genreOnly:
            (true, false)
        case .yearOnly:
            (false, true)
        case .both:
            (true, true)
        }
    }

    var configuredPreviewOnly: Bool {
        dependencies.config.runtime.dryRun
    }

    var configuredMinConfidence: Double {
        let configuredValue = dependencies.config.yearRetrieval.logic.minConfidenceForNewYear / 100
        return min(max(configuredValue, 0.3), 1.0)
    }

    func applyWorkflowDefaults() {
        workflowViewModel?.updateDefaults(
            updateGenre: configuredUpdateSelection.updateGenre,
            updateYear: configuredUpdateSelection.updateYear,
            previewOnly: configuredPreviewOnly,
            minConfidence: configuredMinConfidence,
            releaseYearRestoreThreshold: dependencies.config.processing.releaseYearRestoreThreshold
        )
    }

    func loadCachedSnapshot() {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    func saveMetricsSnapshot(from loadedTracks: [Track]) {
        guard !loadedTracks.isEmpty else { return }

        let total = loadedTracks.count
        var genreCount = 0
        var yearCount = 0
        var bothCount = 0
        var recentCount = 0
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now)

        for track in loadedTracks {
            let hasGenre = hasPresentDashboardGenre(track.genre)
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

        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        let existing = try? modelContext.fetch(descriptor).first

        if let snapshot = existing {
            snapshot.previousTotalTracks = snapshot.totalTracks
            snapshot.previousTracksNeedingGenre = snapshot.tracksNeedingGenre
            snapshot.previousTracksNeedingYear = snapshot.tracksNeedingYear
            snapshot.previousRecentlyAdded = snapshot.recentlyAdded

            snapshot.totalTracks = total
            snapshot.tracksWithGenre = genreCount
            snapshot.tracksWithYear = yearCount
            snapshot.tracksWithBoth = bothCount
            snapshot.tracksNeedingGenre = total - genreCount
            snapshot.tracksNeedingYear = total - yearCount
            snapshot.recentlyAdded = recentCount
            snapshot.timestamp = .now
        } else {
            let snapshot = PersistedMetricsSnapshot(
                totalTracks: total,
                tracksWithGenre: genreCount,
                tracksWithYear: yearCount,
                tracksWithBoth: bothCount,
                tracksNeedingGenre: total - genreCount,
                tracksNeedingYear: total - yearCount,
                recentlyAdded: recentCount
            )
            modelContext.insert(snapshot)
        }

        try? modelContext.save()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    private func recordLibraryLoad(
        source: String,
        count: Int,
        startedAt loadStart: ContinuousClock.Instant
    ) async {
        await dependencies.analyticsService?.trackEvent(
            "library.load",
            duration: loadStart.duration(to: .now),
            metadata: [
                "source": source,
                "trackCount": "\(count)",
            ]
        )
    }

    private func libraryLoadError(from error: Error) -> LibraryLoadError {
        guard let musicLibraryError = error as? MusicLibraryError else {
            return .failed(error.localizedDescription)
        }

        switch musicLibraryError {
        case .authorizationDenied, .authorizationRestricted:
            return .permissionDenied
        case .fetchFailed, .musicAppNotAvailable:
            return .failed(error.localizedDescription)
        }
    }
}

func hasPresentDashboardGenre(_ genre: String?) -> Bool {
    guard let genre else { return false }
    return !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
