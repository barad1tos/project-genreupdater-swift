import Core
import DesignUI
import Foundation
import Services
import SharedUI
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
    @State private var currentRunLifecycle: RunLifecycleSnapshot?
    @State private var hasStartedInitialLoad = false
    @State private var libraryLoadRequestID = UUID()
    @State private var workflowViewModel: WorkflowViewModel?
    @State private var updateScopeTracks: [Core.Track]?
    @State private var workflowNoticeMessage: String?
    @State private var selectedBrowseAlbum: (album: DesignUI.Album, artist: String)?
    @State private var selectedRoute: Route? = .activity
    @State private var activityProjection: ActivityProjection = .empty()
    @State private var activityCommandNoticeMessage: String?
    @State private var activityCommandNoticeID = UUID()
    @AppStorage("defaultUpdateBehavior") private var defaultUpdateBehavior = UpdateBehavior.both.rawValue
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("fastAnimations") private var fastAnimations = false

    var body: some View {
        RootView(
            data: snapshot,
            selectedRoute: $selectedRoute,
            pipelinePrimaryAction: reviewActivityChanges,
            pipelineSecondaryAction: runManualSync,
            setDryRunAction: setDryRunMode,
            setUpdateBehaviorAction: setDefaultUpdateBehavior,
            setMinimumConfidenceAction: setMinimumConfidence,
            setReleaseYearRestoreThresholdAction: setReleaseYearRestoreThreshold,
            setTestArtistsAction: setTestArtists,
            setAppearanceModeAction: setAppearanceMode,
            setFastAnimationsAction: setFastAnimationsEnabled,
            browseAlbumUpdateAction: prepareAlbumUpdate,
            browseAlbumSelectionAction: setSelectedBrowseAlbum
        ) {
            updateContent
        }
        .task {
            await startInitialLoadIfNeeded()
        }
        .task { await observeActivityProjectionUpdates() }
        .task { await observeRunLifecycleUpdates() }
        .onChange(of: defaultUpdateBehavior) {
            applyWorkflowDefaults()
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: dependencies.config.runtime.dryRun) {
            applyWorkflowDefaults()
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: dependencies.config.yearRetrieval.logic.minConfidenceForNewYear) {
            applyWorkflowDefaults()
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: dependencies.config.processing.releaseYearRestoreThreshold) {
            applyWorkflowDefaults()
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: dependencies.config.development.testArtists) {
            handleTestArtistScopeChange()
        }
        .onChange(of: dependencies.isAutoSyncRunning) {
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: workflowDashboardState) {
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: workflowViewModel?.pendingVerificationReportSummary) {
            scheduleActivityProjectionRefresh()
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
            from: designActivitySnapshotInput,
            activityProjection: activityProjection,
            activityNotice: activityCommandNoticeMessage
        )
    }

    private var designActivitySnapshotInput: DesignActivitySnapshotInput {
        DesignActivitySnapshotInput(
            tracks: tracks,
            metricsSnapshot: metricsSnapshot,
            lastScanDate: lastScanDate,
            isLoading: isLoading,
            loadError: loadError,
            isDryRun: dependencies.config.runtime.dryRun,
            workflow: workflowDashboardState,
            pendingVerification: workflowViewModel?.pendingVerificationReportSummary,
            changeLogEntries: changeLogEntries,
            isAutoSyncRunning: dependencies.isAutoSyncRunning,
            runLifecycle: currentRunLifecycle,
            settings: settingsSnapshot,
            now: Date()
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

    private var settingsSnapshot: DesignSettingsSnapshot {
        DesignSettingsSnapshot(
            updateBehavior: DesignUpdateBehavior(rawValue: defaultUpdateBehavior) ?? .both,
            minimumConfidencePercent: dependencies.config.yearRetrieval.logic.minConfidenceForNewYear,
            releaseYearRestoreThresholdYears: dependencies.config.processing.releaseYearRestoreThreshold,
            testArtists: ArtistAllowList.normalized(dependencies.config.development.testArtists),
            appearanceMode: designAppearanceMode(from: appearanceMode),
            isFastAnimationsEnabled: fastAnimations,
            // Writes must always be verified before the app reports them as complete.
            isPostWriteVerificationRequired: true
        )
    }

    private var activityProjectionInput: ActivityProjectionInput {
        ActivityProjectionInputAssembler.makeInput(from: ActivityProjectionAssemblyContext(
            tracks: tracks,
            metricsSnapshot: metricsSnapshot,
            lastScanDate: lastScanDate,
            loadError: loadError,
            isLoading: isLoading,
            isDryRun: dependencies.config.runtime.dryRun,
            workflow: workflowDashboardState,
            pendingVerification: workflowViewModel?.pendingVerificationReportSummary,
            runLifecycle: currentRunLifecycle,
            isLibrarySyncAvailable: dependencies.isManualRunAvailable,
            isAutoSyncRunning: dependencies.isAutoSyncRunning,
            now: Date()
        ))
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

    private func setDefaultUpdateBehavior(_ behavior: DesignUpdateBehavior) -> Bool {
        defaultUpdateBehavior = behavior.rawValue
        applyWorkflowDefaults()
        return true
    }

    private func setMinimumConfidence(_ percent: Double) -> Bool {
        let normalizedPercent = min(max(percent, 30), 100)
        return mutateConfiguration(dependencies) { configuration in
            configuration.yearRetrieval.logic.minConfidenceForNewYear = normalizedPercent
        }
    }

    private func setReleaseYearRestoreThreshold(_ years: Int) -> Bool {
        let normalizedYears = min(max(years, 0), 100)
        return mutateConfiguration(dependencies) { configuration in
            configuration.processing.releaseYearRestoreThreshold = normalizedYears
        }
    }

    private func setTestArtists(_ artists: [String]) -> Bool {
        var normalizedArtists: [String] = []
        for artist in artists {
            let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedArtist.isEmpty else { continue }
            let alreadyExists = normalizedArtists.contains { existingArtist in
                existingArtist.localizedCaseInsensitiveCompare(trimmedArtist) == .orderedSame
            }
            guard !alreadyExists else { continue }
            normalizedArtists.append(trimmedArtist)
        }

        return mutateConfiguration(dependencies) { configuration in
            configuration.development.testArtists = normalizedArtists
        }
    }

    private func setAppearanceMode(_ mode: DesignAppearanceMode) -> Bool {
        appearanceMode = appAppearanceMode(from: mode)
        return true
    }

    private func setFastAnimationsEnabled(_ isEnabled: Bool) -> Bool {
        fastAnimations = isEnabled
        return true
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

    private func reviewActivityChanges() {
        clearActivityCommandNotice()
        Task { @MainActor in
            await reviewActivityChangesCommand()
        }
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

        Task { @MainActor in
            await refreshActivityProjection()
            await loadLibrary(forceRefresh: true)
        }
    }

    private func startInitialLoadIfNeeded() async {
        guard !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        ensureWorkflowViewModel()
        await loadLibrary()
        await refreshActivityProjection()
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
            await refreshActivityProjection()
            return
        }

        isLoading = true
        await refreshActivityProjection()

        let shouldRefreshProjection = await loadLiveLibrary(
            provider: provider,
            requestID: requestID,
            scopedArtists: scopedArtists,
            loadStart: loadStart,
            hasCachedTracks: hasCachedTracks
        )
        guard shouldRefreshProjection else { return }
        await refreshActivityProjection()
    }

    private func loadLiveLibrary(
        provider: LibraryReadProvider,
        requestID: UUID,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        hasCachedTracks: Bool
    ) async -> Bool {
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
            return isCurrentLibraryLoad(requestID)
        } catch {
            await handleLibraryLoadFailure(error, hasCachedTracks: hasCachedTracks, requestID: requestID)
        }

        return isCurrentLibraryLoad(requestID)
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

    @discardableResult
    private func refreshActivityProjection() async -> ActivityProjection {
        let inputGeneration = await dependencies.projectionStore.nextActivityProjectionInputGeneration()
        let projectionInput = activityProjectionInput
        let projection = ActivityProjectionBuilder.makeProjection(from: projectionInput)
        let storedProjection = await dependencies.projectionStore.replaceActivityProjection(
            projection,
            inputGeneration: inputGeneration
        )
        applyActivityProjection(storedProjection)
        return storedProjection
    }

    private func applyActivityProjection(_ projection: ActivityProjection) {
        guard projection.revision > activityProjection.revision else { return }
        activityProjection = projection
    }

    private func observeActivityProjectionUpdates() async {
        for await projection in await dependencies.projectionStore.activityUpdates() {
            applyActivityProjection(projection)
        }
    }

    private func observeRunLifecycleUpdates() async {
        for await lifecycle in await dependencies.runLifecycleUpdates() {
            currentRunLifecycle = lifecycle
            await refreshActivityProjection()
        }
    }

    private func scheduleActivityProjectionRefresh() {
        Task { @MainActor in
            await refreshActivityProjection()
        }
    }

    private var activityCommandController: ActivityCommandController {
        ActivityCommandController(
            isRunOrchestratorAvailable: { dependencies.runOrchestrator != nil },
            hasActiveRun: { currentRunLifecycle?.isActive == true },
            submitManualObservationRun: {
                try await dependencies.submitManualObservationRun()
            },
            reloadLibrary: { forceRefresh in
                await loadLibrary(forceRefresh: forceRefresh)
            },
            refreshActivityProjection: {
                await refreshActivityProjection()
            }
        )
    }

    private func runManualSync(_ action: PipelineAction) {
        guard action.isEnabled else { return }
        runManualSync()
    }

    private func runManualSync() {
        clearActivityCommandNotice()
        Task { @MainActor in
            await runManualSyncCommand()
        }
    }

    @discardableResult
    private func runManualSyncCommand() async -> UserCommandResult {
        let command = UserIntentCommand.runManually()
        let result = await activityCommandController.handle(command)
        handleActivityCommandResult(result)
        return result
    }

    @discardableResult
    private func reviewActivityChangesCommand() async -> UserCommandResult {
        let command = UserIntentCommand.reviewChanges()
        let result = await activityCommandController.handle(command)
        handleActivityCommandResult(result)
        return result
    }

    private func handleActivityCommandResult(_ result: UserCommandResult) {
        if let refreshedProjection = result.refreshedActivityProjection {
            applyActivityProjection(refreshedProjection)
        }
        handleActivityNavigationTarget(result.navigationTarget)
        setActivityCommandNotice(result.message)
    }

    private func handleActivityNavigationTarget(_ target: CommandNavigationTarget?) {
        switch target {
        case .fixPlan:
            prepareDefaultUpdateForReview()
        case .activity:
            selectedRoute = .activity
        case .report:
            selectedRoute = .reports
        case .settings:
            selectedRoute = .settings
        case nil:
            break
        }
    }

    private func setActivityCommandNotice(_ message: String) {
        guard !message.isEmpty else {
            clearActivityCommandNotice()
            return
        }

        let noticeID = UUID()
        activityCommandNoticeID = noticeID
        activityCommandNoticeMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard activityCommandNoticeID == noticeID else { return }
            clearActivityCommandNotice()
        }
    }

    private func clearActivityCommandNotice() {
        activityCommandNoticeID = UUID()
        activityCommandNoticeMessage = nil
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
