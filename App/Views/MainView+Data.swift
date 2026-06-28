// MainView+Data.swift -- library loading, workflow defaults, and metrics snapshots.

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

extension MainView {
    func startLibraryLoad(forceRefresh: Bool = false) {
        let requestID = UUID()
        libraryLoadRequestID = requestID
        libraryLoadTask?.cancel()
        libraryLoadTask = Task {
            await loadTracks(forceRefresh: forceRefresh, requestID: requestID)
        }
    }

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
        await loadTracks(forceRefresh: forceRefresh, requestID: UUID())
    }

    private func loadTracks(forceRefresh: Bool, requestID: UUID) async {
        libraryLoadRequestID = requestID
        libraryLoadError = nil
        isMutationMetadataReady = false
        loadCachedSnapshot()
        ensureWorkflowViewModel()

        defer {
            if libraryLoadRequestID == requestID {
                isLoading = false
                libraryLoadTask = nil
            }
        }

        guard let reader = LibraryTrackLoader.liveReader(from: dependencies) else { return }
        isLoading = true

        let loadStart = ContinuousClock.now
        let scopedArtists = LibraryTrackLoader.scopedArtists(from: dependencies)
        var hasCachedTracks = false

        do {
            if let cachedLoad = await LibraryTrackLoader.cachedSnapshot(
                from: dependencies,
                scopedArtists: scopedArtists,
                forceRefresh: forceRefresh
            ) {
                try Task.checkCancellation()
                guard libraryLoadRequestID == requestID else { return }
                tracks = cachedLoad.tracks
                browseViewModel.tracks = cachedLoad.tracks
                reconcileUpdateScope(with: cachedLoad.tracks)
                hasCachedTracks = cachedLoad.hasTracks
                await recordLibraryLoad(source: "snapshot", count: cachedLoad.tracks.count, startedAt: loadStart)
            }
            try Task.checkCancellation()
            let liveLoad = try await LibraryTrackLoader.liveTracks(
                from: dependencies,
                reader: reader,
                scopedArtists: scopedArtists
            )
            guard libraryLoadRequestID == requestID else { return }
            isMutationMetadataReady = liveLoad.isMutationMetadataReady
            tracks = liveLoad.tracks
            await dependencies.persistLoadedLibraryTracks(liveLoad.tracks, scopedArtists: scopedArtists)
            browseViewModel.tracks = liveLoad.tracks
            reconcileUpdateScope(with: liveLoad.tracks)
            lastLibraryScanDate = liveLoad.scanDate
            saveMetricsSnapshot(from: liveLoad.tracks)
            await recordLibraryLoad(source: "music", count: liveLoad.tracks.count, startedAt: loadStart)
        } catch is CancellationError {
            return
        } catch {
            guard libraryLoadRequestID == requestID else { return }
            await dependencies.analyticsService?.trackError("library.load", error: error)
            libraryLoadError = LibraryLoadError.make(from: error)
            if !hasCachedTracks {
                tracks = []
                browseViewModel.tracks = []
            }
        }
    }
    func ensureWorkflowViewModel() {
        guard workflowViewModel == nil,
              let coordinator = dependencies.updateCoordinator,
              let pipeline = dependencies.changePreviewPipeline,
              let processor = dependencies.batchProcessor
        else { return }

        workflowViewModel = WorkflowViewModel(
            dependencies: WorkflowViewModel.Dependencies(
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
                resolveIncrementalTracks: { tracks, options in
                    let lastRunTime = await dependencies.incrementalRunTracker?.getLastRunTimestamp()
                    return UpdateTrackScopeResolver.incrementalTracks(
                        tracks,
                        lastRunTime: lastRunTime,
                        previousTracks: dependencies.previousIncrementalScopeTracks,
                        options: options
                    )
                },
                invalidateAlbumYearCache: {
                    await dependencies.cacheService?.invalidateAllAlbumYears()
                },
                updateIncrementalRunTimestamp: {
                    await dependencies.incrementalRunTracker?.updateLastRunTimestamp()
                },
                problematicAlbumReportMinAttempts: {
                    max(1, Int(dependencies.config.reporting.minAttemptsForReport.rounded()))
                }
            ),
            defaults: WorkflowViewModel.Defaults(
                updateGenre: configuredUpdateSelection.updateGenre,
                updateYear: configuredUpdateSelection.updateYear,
                previewOnly: configuredPreviewOnly,
                minConfidence: configuredMinConfidence,
                releaseYearRestoreThreshold: dependencies.config.processing.releaseYearRestoreThreshold
            )
        )
        applyPendingSelectedUpdateScopeIfNeeded()
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

    func prepareDefaultUpdate() {
        ensureWorkflowViewModel()
        guard workflowViewModel?.canStart ?? true else {
            workflowNoticeMessage = "Finish or reset the current update before starting a new update scope."
            selectedCategory = .update
            return
        }

        updateScopeTracks = nil
        pendingSelectedUpdateScopeConfiguration = nil
        applyWorkflowDefaults()
        let scopedLibraryTracks = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: nil,
            mode: .fullLibrary,
            testArtists: dependencies.config.development.testArtists
        )
        workflowViewModel?.configureFullLibraryScope(tracks: scopedLibraryTracks)
        workflowNoticeMessage = nil
        selectedCategory = .update
    }

    func prepareSelectedTracksUpdate() {
        let selectedTracks = browseViewModel.selectedTracksForUpdate()
        let updateSelection = configuredUpdateSelection
        configureSelectedUpdateScope(
            SelectedUpdateScopeConfiguration(
                tracks: selectedTracks,
                updateGenre: updateSelection.updateGenre,
                updateYear: updateSelection.updateYear,
                previewOnly: configuredPreviewOnly
            )
        )
    }

    func handleBrowseAction(_ notification: Notification) {
        guard let request = BrowseUpdateRequest(notification: notification) else { return }

        configureSelectedUpdateScope(selectedUpdateScopeConfiguration(for: request))
    }

    func selectCategory(_ category: NavigationCategory?) {
        selectedCategory = category
        if category == .update {
            ensureWorkflowViewModel()
        }
    }

    var selectedCategoryBinding: Binding<NavigationCategory?> {
        Binding(
            get: { selectedCategory },
            set: { selectCategory($0) }
        )
    }

    var updateWorkflowTracks: [Track] {
        guard let workflowViewModel else { return tracks }
        return UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: updateScopeTracks,
            mode: workflowViewModel.mode,
            testArtists: dependencies.config.development.testArtists
        )
    }

    func reconcileUpdateScope(with loadedTracks: [Track]) {
        updateScopeTracks = UpdateTrackScopeResolver.reconciledSelectedScope(
            currentScopeTracks: updateScopeTracks,
            libraryTracks: loadedTracks,
            testArtists: dependencies.config.development.testArtists
        )

        if workflowViewModel?.mode == .selectedTracks {
            workflowViewModel?.computeScopePreview(tracks: updateScopeTracks ?? [])
        }
    }

    private func configureSelectedUpdateScope(_ configuration: SelectedUpdateScopeConfiguration) {
        ensureWorkflowViewModel()
        guard let workflowViewModel else {
            pendingSelectedUpdateScopeConfiguration = configuration
            updateScopeTracks = configuration.tracks
            selectedCategory = .update
            return
        }

        guard workflowViewModel.canStart else {
            workflowNoticeMessage = "Finish or reset the current update before starting a new Browse selection."
            selectedCategory = .update
            return
        }

        applySelectedUpdateScope(configuration, to: workflowViewModel)
        workflowNoticeMessage = nil
        selectedCategory = .update
    }

    private func applyPendingSelectedUpdateScopeIfNeeded() {
        guard let configuration = pendingSelectedUpdateScopeConfiguration,
              let workflowViewModel,
              workflowViewModel.canStart
        else { return }

        applySelectedUpdateScope(configuration, to: workflowViewModel)
        pendingSelectedUpdateScopeConfiguration = nil
    }

    private func applySelectedUpdateScope(
        _ configuration: SelectedUpdateScopeConfiguration,
        to workflowViewModel: WorkflowViewModel
    ) {
        let scopedTracks = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: configuration.tracks,
            mode: .selectedTracks,
            testArtists: dependencies.config.development.testArtists
        )
        updateScopeTracks = scopedTracks
        workflowViewModel.configureSelectedTracksScope(
            tracks: scopedTracks,
            updateGenre: configuration.updateGenre,
            updateYear: configuration.updateYear,
            previewOnly: configuration.previewOnly
        )
    }

    func selectedUpdateScopeConfiguration(for request: BrowseUpdateRequest) -> SelectedUpdateScopeConfiguration {
        let updateSelection = configuredUpdateSelection
        return SelectedUpdateScopeConfiguration(
            request: request,
            browseViewModel: browseViewModel,
            defaultUpdateGenre: updateSelection.updateGenre,
            defaultUpdateYear: updateSelection.updateYear,
            defaultPreviewOnly: configuredPreviewOnly
        )
    }

    func loadCachedSnapshot() {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    func saveMetricsSnapshot(from loadedTracks: [Track]) {
        metricsSnapshot = upsertDashboardMetricsSnapshot(from: loadedTracks, in: modelContext)
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
}

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

        if hasGenre { genreCount += 1 }
        if hasYear { yearCount += 1 }
        if hasGenre, hasYear { bothCount += 1 }

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
