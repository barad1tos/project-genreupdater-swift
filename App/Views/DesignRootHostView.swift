import Core
import DesignUI
import Services
import SwiftData
import SwiftUI

struct DesignRootHostView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext

    @State private var tracks: [Core.Track] = []
    @State private var metricsSnapshot: PersistedMetricsSnapshot?
    @State private var changeLogEntries: [Core.ChangeLogEntry] = []
    @State private var lastScanDate: Date?
    @State private var isLoading = false
    @State private var isLibraryReadyForUpdates = false
    @State private var loadError: LibraryLoadError?
    @State private var isSynchronizingLibrary = false
    @State private var syncErrorMessage: String?
    @State private var lastSyncResult: SyncResult?
    @State private var hasStartedInitialLoad = false
    @State private var libraryLoadRequestID = UUID()
    @State private var workflowViewModel: WorkflowViewModel?
    @State private var updateScopeTracks: [Core.Track]?
    @State private var workflowNoticeMessage: String?
    @State private var selectedBrowseAlbum: (album: DesignUI.Album, artist: String)?
    @State private var selectedRoute: Route? = .activity
    @AppStorage("defaultUpdateBehavior") private var defaultUpdateBehavior = UpdateBehavior.both.rawValue

    var body: some View {
        RootView(
            data: snapshot,
            selectedRoute: $selectedRoute,
            pipelinePrimaryAction: prepareDefaultUpdateForReview,
            pipelineSecondaryAction: runManualSync,
            setDryRunAction: setDryRunMode,
            browseAlbumUpdateAction: prepareAlbumUpdate,
            browseAlbumSelectionAction: setSelectedBrowseAlbum
        ) {
            updateContent
        }
        .task {
            await startInitialLoadIfNeeded()
        }
        .onChange(of: defaultUpdateBehavior) {
            applyWorkflowDefaults()
        }
        .onChange(of: dependencies.config.runtime.dryRun) {
            applyWorkflowDefaults()
        }
        .onChange(of: dependencies.config.yearRetrieval.logic.minConfidenceForNewYear) {
            applyWorkflowDefaults()
        }
        .onChange(of: dependencies.config.processing.releaseYearRestoreThreshold) {
            applyWorkflowDefaults()
        }
        .onChange(of: dependencies.config.development.testArtists) {
            handleTestArtistScopeChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateSelectedTracks)) { _ in
            prepareSelectedTracksUpdate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToUpdate)) { _ in
            prepareDefaultUpdateForReview()
        }
        .focusedValue(\.selectedCategory, selectedCategoryBinding)
    }

    private var snapshot: DesignDataSnapshot {
        DesignActivitySnapshotAdapter.makeSnapshot(
            from: DesignActivitySnapshotInput(
                tracks: tracks,
                metricsSnapshot: metricsSnapshot,
                lastScanDate: lastScanDate,
                isLoading: isLoading,
                isLibraryReadyForUpdates: isLibraryReadyForUpdates,
                loadError: loadError,
                isDryRun: dependencies.config.runtime.dryRun,
                workflow: workflowDashboardState,
                pendingVerification: workflowViewModel?.pendingVerificationReportSummary,
                changeLogEntries: changeLogEntries,
                isSynchronizingLibrary: isSynchronizingLibrary,
                syncErrorMessage: syncErrorMessage,
                isLibrarySyncAvailable: dependencies.librarySyncService != nil,
                isAutoSyncRunning: dependencies.isAutoSyncRunning,
                lastSyncResult: lastSyncResult,
                now: Date()
            )
        )
    }

    @ViewBuilder
    private var updateContent: some View {
        if let workflowViewModel {
            UpdateWorkflowView(
                viewModel: workflowViewModel,
                tracks: updateWorkflowTracks,
                testArtists: dependencies.config.development.testArtists,
                reportDisplayMode: dependencies.config.reporting.changeDisplayMode,
                credentialIssue: dependencies.discogsCredentialIssue,
                isLibraryReadyForUpdates: !isLoading && isLibraryReadyForUpdates,
                noticeMessage: $workflowNoticeMessage
            )
            .padding(24)
            .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Services Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Update services are still initializing. Please wait.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workflowDashboardState: WorkflowDashboardState {
        workflowViewModel?.dashboardState ?? .empty
    }

    private var configuredUpdateSelection: (updateGenre: Bool, updateYear: Bool) {
        switch UpdateBehavior(rawValue: defaultUpdateBehavior) ?? .both {
        case .genreOnly:
            (true, false)
        case .yearOnly:
            (false, true)
        case .both:
            (true, true)
        }
    }

    private var configuredPreviewOnly: Bool {
        dependencies.config.runtime.dryRun
    }

    private var configuredMinConfidence: Double {
        let configuredValue = dependencies.config.yearRetrieval.logic.minConfidenceForNewYear / 100
        return min(max(configuredValue, 0.3), 1.0)
    }

    private var updateWorkflowTracks: [Core.Track] {
        guard let workflowViewModel else { return tracks }
        return UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: updateScopeTracks,
            mode: workflowViewModel.mode,
            testArtists: dependencies.config.development.testArtists
        )
    }

    private func ensureWorkflowViewModel() {
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
                prepareMutationMetadata: { tracks in
                    _ = try await dependencies.refreshTrackIDMappingOrThrow(
                        musicKitTracks: tracks,
                        scopedArtists: dependencies.config.development.testArtists,
                        mergeExisting: true
                    )
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
    }

    private func applyWorkflowDefaults() {
        workflowViewModel?.updateDefaults(
            updateGenre: configuredUpdateSelection.updateGenre,
            updateYear: configuredUpdateSelection.updateYear,
            previewOnly: configuredPreviewOnly,
            minConfidence: configuredMinConfidence,
            releaseYearRestoreThreshold: dependencies.config.processing.releaseYearRestoreThreshold
        )
    }

    private func setDryRunMode(_ isDryRun: Bool) -> Bool {
        let didSave = mutateConfiguration(dependencies) { configuration in
            configuration.runtime.dryRun = isDryRun
        }
        if didSave {
            applyWorkflowDefaults()
        }
        return didSave
    }

    private func prepareDefaultUpdateForReview() {
        selectedRoute = .update
        ensureWorkflowViewModel()
        guard let workflowViewModel else {
            workflowNoticeMessage = "Update services are still initializing. Please wait."
            return
        }

        if workflowDashboardState.proposedChangeCount > 0 {
            workflowNoticeMessage = nil
            return
        }

        guard !isLoading, isLibraryReadyForUpdates else {
            workflowNoticeMessage = "Wait for the live library scan to finish before reviewing changes."
            return
        }

        guard workflowViewModel.canStart else {
            workflowNoticeMessage = "Finish or reset the current update before starting a new update scope."
            return
        }

        updateScopeTracks = nil
        applyWorkflowDefaults()
        let scopedLibraryTracks = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: nil,
            mode: .fullLibrary,
            testArtists: dependencies.config.development.testArtists
        )
        workflowViewModel.configureFullLibraryScope(tracks: scopedLibraryTracks)
        workflowViewModel.previewOnly = true
        workflowNoticeMessage = nil
        workflowViewModel.start(tracks: scopedLibraryTracks)
    }

    private func prepareAlbumUpdate(album: DesignUI.Album, artist: String) {
        let selectedTracks = tracksForAlbumUpdate(album: album, artist: artist)
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

    private func prepareSelectedTracksUpdate() {
        guard let selectedBrowseAlbum else {
            ensureWorkflowViewModel()
            selectedRoute = .update
            workflowNoticeMessage = "Select an album in Browse before using Update Selected Tracks."
            return
        }

        prepareAlbumUpdate(album: selectedBrowseAlbum.album, artist: selectedBrowseAlbum.artist)
    }

    private func setSelectedBrowseAlbum(album: DesignUI.Album?, artist: String?) {
        if let album, let artist {
            selectedBrowseAlbum = (album, artist)
        } else {
            selectedBrowseAlbum = nil
        }
    }

    private func configureSelectedUpdateScope(_ configuration: SelectedUpdateScopeConfiguration) {
        selectedRoute = .update
        ensureWorkflowViewModel()
        guard let workflowViewModel else {
            updateScopeTracks = configuration.tracks
            workflowNoticeMessage = "Update services are still initializing. Please wait."
            return
        }

        guard workflowViewModel.canStart else {
            workflowNoticeMessage = "Finish or reset the current update before starting a new Browse selection."
            return
        }

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
        workflowNoticeMessage = scopedTracks.isEmpty
            ? "No tracks matched this album in the current library scope."
            : nil
    }

    private func tracksForAlbumUpdate(album: DesignUI.Album, artist: String) -> [Core.Track] {
        let albumKeys = Set(AlbumIdentity.lookupKeys(artist: artist, album: album.name))
        return tracks.filter { track in
            !Set(AlbumIdentity.lookupKeys(for: track)).isDisjoint(with: albumKeys)
        }
    }

    private func reconcileUpdateScope(with loadedTracks: [Core.Track]) {
        updateScopeTracks = UpdateTrackScopeResolver.reconciledSelectedScope(
            currentScopeTracks: updateScopeTracks,
            libraryTracks: loadedTracks,
            testArtists: dependencies.config.development.testArtists
        )

        guard let workflowViewModel, workflowViewModel.canStart else { return }
        workflowViewModel.computeScopePreview(tracks: updateWorkflowTracks)
    }

    private func handleTestArtistScopeChange() {
        guard workflowViewModel?.canStart ?? true else {
            workflowNoticeMessage = "Finish or reset the current update before changing the test artist scope."
            return
        }

        updateScopeTracks = nil
        workflowNoticeMessage = nil
        tracks = []
        metricsSnapshot = nil
        lastScanDate = nil
        workflowViewModel?.reset()
        applyWorkflowDefaults()

        Task {
            await loadLibrary(forceRefresh: true)
        }
    }

    private func startInitialLoadIfNeeded() async {
        guard !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        ensureWorkflowViewModel()
        await loadLibrary()
    }

    private func loadLibrary(forceRefresh: Bool = false) async {
        let requestID = UUID()
        libraryLoadRequestID = requestID
        loadError = nil
        isLibraryReadyForUpdates = false
        loadCachedMetrics()
        loadChangeLogEntries()
        await dependencies.refreshAutoSyncStatus()
        guard isCurrentLibraryLoad(requestID) else { return }

        let scopedArtists = LibraryTrackLoader.scopedArtists(from: dependencies)
        let loadStart = ContinuousClock.now
        let hasCachedTracks = await applyCachedLibraryLoad(
            requestID: requestID,
            scopedArtists: scopedArtists,
            loadStart: loadStart,
            forceRefresh: forceRefresh
        )
        guard isCurrentLibraryLoad(requestID) else { return }

        guard let provider = LibraryTrackLoader.liveProvider(from: dependencies) else {
            finishLibraryLoadIfCurrent(requestID)
            return
        }

        isLoading = true
        defer { finishLibraryLoadIfCurrent(requestID) }

        do {
            let liveLoad = try await LibraryTrackLoader.liveTracks(
                provider: provider,
                scopedArtists: scopedArtists
            )
            await applyLiveLibraryLoad(
                liveLoad,
                requestID: requestID,
                scopedArtists: scopedArtists,
                loadStart: loadStart
            )
        } catch is CancellationError {
            return
        } catch {
            await handleLibraryLoadFailure(error, hasCachedTracks: hasCachedTracks, requestID: requestID)
        }
    }

    private func applyCachedLibraryLoad(
        requestID: UUID,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        forceRefresh: Bool
    ) async -> Bool {
        guard let cachedLoad = await LibraryTrackLoader.cachedSnapshot(
            from: dependencies,
            scopedArtists: scopedArtists,
            forceRefresh: forceRefresh
        ) else { return false }

        guard isCurrentLibraryLoad(requestID) else { return false }
        tracks = cachedLoad.tracks
        reconcileUpdateScope(with: cachedLoad.tracks)
        await recordLibraryLoad(source: "snapshot", count: cachedLoad.tracks.count, startedAt: loadStart)
        return cachedLoad.hasTracks
    }

    private func applyLiveLibraryLoad(
        _ liveLoad: LibraryLiveTrackLoad,
        requestID: UUID,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant
    ) async {
        guard isCurrentLibraryLoad(requestID) else { return }
        isLibraryReadyForUpdates = liveLoad.isLibraryReadyForUpdates
        tracks = liveLoad.tracks
        await dependencies.persistLoadedLibraryTracks(liveLoad.tracks, scopedArtists: scopedArtists)
        guard isCurrentLibraryLoad(requestID) else { return }
        reconcileUpdateScope(with: liveLoad.tracks)
        lastScanDate = liveLoad.scanDate
        metricsSnapshot = upsertDashboardMetricsSnapshot(from: liveLoad.tracks, in: modelContext)
        await recordLibraryLoad(source: "music", count: liveLoad.tracks.count, startedAt: loadStart)
    }

    private func handleLibraryLoadFailure(
        _ error: any Error,
        hasCachedTracks: Bool,
        requestID: UUID
    ) async {
        guard isCurrentLibraryLoad(requestID) else { return }
        await dependencies.analyticsService?.trackError("library.load", error: error)
        loadError = LibraryLoadError.make(from: error)
        if !hasCachedTracks {
            tracks = []
        }
    }

    private func finishLibraryLoadIfCurrent(_ requestID: UUID) {
        if isCurrentLibraryLoad(requestID) {
            isLoading = false
        }
    }

    private func isCurrentLibraryLoad(_ requestID: UUID) -> Bool {
        libraryLoadRequestID == requestID
    }

    private func loadCachedMetrics() {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    private func loadChangeLogEntries() {
        var descriptor = FetchDescriptor<PersistedChangeLogEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = DesignActivitySnapshotAdapter.reportEntryLimit
        changeLogEntries = (try? modelContext.fetch(descriptor).map { $0.toChangeLogEntry() }) ?? []
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
                "trackCount": "\(count)"
            ]
        )
    }

    private func runManualSync() {
        guard !isSynchronizingLibrary else { return }

        isSynchronizingLibrary = true
        syncErrorMessage = nil

        Task { @MainActor in
            do {
                let result = try await dependencies.synchronizeLibraryNow()
                lastSyncResult = result
                await loadLibrary(forceRefresh: true)
                isSynchronizingLibrary = false
            } catch {
                lastSyncResult = nil
                syncErrorMessage = error.localizedDescription
                isSynchronizingLibrary = false
            }
        }
    }

    private var selectedCategoryBinding: Binding<NavigationCategory?> {
        Binding {
            NavigationCategory(designRoute: selectedRoute)
        } set: { category in
            selectCategory(category)
        }
    }

    private func selectCategory(_ category: NavigationCategory?) {
        selectedRoute = category?.designRoute ?? .activity
        if category == .update {
            ensureWorkflowViewModel()
        }
    }
}

extension NavigationCategory {
    fileprivate var designRoute: Route {
        switch self {
        case .dashboard:
            .activity
        case .browse:
            .browse
        case .reports:
            .reports
        case .update:
            .update
        }
    }

    fileprivate init?(designRoute: Route?) {
        switch designRoute ?? .activity {
        case .activity:
            self = .dashboard
        case .browse:
            self = .browse
        case .reports:
            self = .reports
        case .update:
            self = .update
        case .settings:
            return nil
        }
    }
}
