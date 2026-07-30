// swiftlint:disable file_length

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
    @State private var reportsProjection: ReportsProjection = .empty()
    @State private var fixPlanProjection: FixPlanProjection = .empty()
    @State private var selectedRunReport: RunReportDetailSnapshot?
    @State private var runReportDetailRequestID = UUID()
    @State private var activityCommandNoticeMessage: String?
    @State private var activityCommandNoticeID = UUID()
    @State private var fixPlanNoticeMessage: String?
    @State private var fixPlanNoticeTone: Tone = .info
    @State private var fixPlanNoticeID = UUID()
    @State private var isReviewBusy = false
    @State private var queuedManualReload: QueuedManualReload?
    @AppStorage(AppStorageKey.defaultUpdateBehavior) private var defaultUpdateBehavior = UpdateBehavior.both.rawValue
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("fastAnimations") private var fastAnimations = false

    var body: some View {
        RootView(
            data: snapshot,
            selectedRoute: $selectedRoute,
            pipelinePrimaryAction: runPrimaryCommand,
            pipelineSecondaryAction: runManualSync,
            setDryRunAction: setDryRunMode,
            setUpdateBehaviorAction: setDefaultUpdateBehavior,
            setMinimumConfidenceAction: setMinimumConfidence,
            setReleaseYearRestoreThresholdAction: setReleaseYearRestoreThreshold,
            setTestArtistsAction: setTestArtists,
            setAppearanceModeAction: setAppearanceMode,
            setFastAnimationsAction: setFastAnimationsEnabled,
            browseAlbumUpdateAction: prepareAlbumUpdate,
            browseAlbumSelectionAction: setSelectedBrowseAlbum,
            reportRunSelectionAction: selectRunReport
        ) {
            updateContent
        }
        .task {
            await startInitialLoadIfNeeded()
            await refreshFixPlanProjection()
        }
        .task { await observeActivityProjectionUpdates() }
        .task { await observeReportsProjectionUpdates() }
        .task { await observeFixPlanUpdates() }
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
        ActivitySnapshotAdapter.makeSnapshot(
            from: designActivitySnapshotInput,
            activityProjection: activityProjection,
            reportsProjection: reportsProjection,
            selectedRunReport: selectedRunReport,
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

    private var activeRunID: RunID? {
        currentRunLifecycle?.isActive == true ? currentRunLifecycle?.runID : nil
    }

    @ViewBuilder
    private var updateContent: some View {
        if fixPlanProjection.status != .empty {
            FixPlanView(
                snapshot: FixPlanAdapter.makeSnapshot(from: fixPlanProjection),
                noticeMessage: fixPlanNoticeMessage,
                noticeTone: fixPlanNoticeTone,
                isReviewBusy: isReviewBusy,
                onAccept: acceptFixPlan,
                onApply: applyFixPlan,
                onReject: rejectFixPlan,
                onToggleItem: toggleFixPlanItem
            )
        } else if let workflowViewModel {
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
        UpdateBehavior.resolved(from: defaultUpdateBehavior).enabledTargets
    }

    private var configuredPreviewOnly: Bool {
        dependencies.config.runtime.dryRun
    }

    private var configuredMinConfidence: Double {
        UpdateOptions.clampedConfidenceRatio(
            dependencies.config.yearRetrieval.logic.minConfidenceForNewYear / 100
        )
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
        ActivityInputBuilder.makeInput(from: ActivityInputContext(
            tracks: tracks,
            metricsSnapshot: metricsSnapshot,
            lastScanDate: lastScanDate,
            loadError: loadError,
            isLoading: isLoading,
            isDryRun: dependencies.config.runtime.dryRun,
            workflow: workflowDashboardState,
            fixPlanProjection: fixPlanProjection,
            reportsProjection: reportsProjection,
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
                ensureRecoveryHold: {
                    await dependencies.ensureRecoveryHold()
                },
                clearRecovery: { id in
                    try await dependencies.clearRecoveryHold(id: id)
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
        let normalizedArtists = ArtistAllowList.normalized(artists)

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

    private func runPrimaryCommand() {
        guard let command = ActivityCommands.command(for: activityProjection.primaryCommand) else { return }
        clearActivityCommandNotice()
        Task { @MainActor in
            await runActivityCommand(command)
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

    private func selectRunReport(_ runID: String?) {
        // New request ID invalidates any in-flight detail load, so a stale
        // response can neither reopen a closed card nor overwrite a newer pick.
        let requestID = UUID()
        runReportDetailRequestID = requestID
        guard let runID else {
            selectedRunReport = nil
            return
        }
        Task { @MainActor in
            await loadRunReportDetail(runID: runID, requestID: requestID)
        }
    }

    private func loadRunReportDetail(runID: String, requestID: UUID) async {
        let record = await dependencies.loadRunReportRecord(id: runID)
        guard runReportDetailRequestID == requestID else { return }

        guard let record else {
            selectedRunReport = .unavailable(runID: runID)
            return
        }
        let detail = RunReportDetailBuilder.makeDetail(from: record, now: Date(), activeRunID: activeRunID)
        selectedRunReport = ReportDetailAdapter.makeSnapshot(from: detail)
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
        if await dependencies.ensureRecoveryHold() {
            _ = await workflowViewModel?.stopForRecoveryHold()
        }
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
        await refreshReportsProjection()
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
        descriptor.fetchLimit = ActivitySnapshotAdapter.reportEntryLimit
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
        let projection = ActivityBuilder.makeProjection(from: projectionInput)
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
            if !lifecycle.isActive {
                let reloadAdvance = advanceQueuedReload(queuedManualReload, lifecycle: lifecycle)
                queuedManualReload = reloadAdvance.next
                if reloadAdvance.shouldReload {
                    await loadLibrary(forceRefresh: true)
                }
                if lifecycle.intent == .previewFixes {
                    await refreshFixPlanProjection()
                }
                await refreshReportsProjection()
            }
        }
    }

    private func scheduleActivityProjectionRefresh() {
        Task { @MainActor in
            await refreshActivityProjection()
        }
    }

    @discardableResult
    private func refreshReportsProjection() async -> ReportsProjection? {
        let inputGeneration = await dependencies.projectionStore.nextReportsProjectionInputGeneration()
        guard let page = await dependencies.loadRunReportPage(
            limit: RunHistoryAdapter.runHistoryLimit
        ) else { return nil }
        let projection = ReportsBuilder.makeProjection(from: RunHistoryAdapter.makeInput(
            from: page,
            now: Date(),
            activeRunID: activeRunID
        ))
        let storedProjection = await dependencies.projectionStore.replaceReportsProjection(
            projection,
            inputGeneration: inputGeneration
        )
        if applyReportsProjection(storedProjection) {
            await refreshActivityProjection()
        }
        return storedProjection
    }

    private func applyReportsProjection(_ projection: ReportsProjection) -> Bool {
        guard projection.revision > reportsProjection.revision else { return false }
        reportsProjection = projection
        return true
    }

    private func observeReportsProjectionUpdates() async {
        for await projection in await dependencies.projectionStore.reportsUpdates()
            where applyReportsProjection(projection) {
            await refreshActivityProjection()
        }
    }

    private func applyFixPlanProjection(_ projection: FixPlanProjection) -> Bool {
        guard projection.revision > fixPlanProjection.revision else { return false }
        fixPlanProjection = projection
        return true
    }

    @discardableResult
    private func refreshFixPlanProjection() async -> FixPlanProjection {
        let projection = await dependencies.refreshFixPlanProjection()
        if applyFixPlanProjection(projection) {
            await refreshActivityProjection()
        }
        return projection
    }

    private func observeFixPlanUpdates() async {
        for await projection in await dependencies.projectionStore.fixPlanUpdates()
            where applyFixPlanProjection(projection) {
            await refreshActivityProjection()
        }
    }

    @discardableResult
    private func runActivityCommand(_ command: UserIntentCommand) async -> UserCommandResult {
        let result = await activityCommands.handle(command)
        handleCommandResult(result)
        return result
    }

    private func handleCommandResult(_ result: UserCommandResult, showsActivityNotice: Bool = true) {
        if let refreshedProjection = result.refreshedFixPlanProjection {
            _ = applyFixPlanProjection(refreshedProjection)
        }
        if let refreshedProjection = result.refreshedActivityProjection {
            applyActivityProjection(refreshedProjection)
        }
        applyNavigationTarget(result.navigationTarget)
        if showsActivityNotice {
            setActivityCommandNotice(result.message)
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

    private func setFixPlanNotice(_ message: String, tone: Tone) {
        guard !message.isEmpty else {
            clearFixPlanNotice()
            return
        }

        let noticeID = UUID()
        fixPlanNoticeID = noticeID
        fixPlanNoticeTone = tone
        fixPlanNoticeMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard fixPlanNoticeID == noticeID else { return }
            clearFixPlanNotice()
        }
    }

    private func clearFixPlanNotice() {
        fixPlanNoticeID = UUID()
        fixPlanNoticeMessage = nil
        fixPlanNoticeTone = .info
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

extension DesignRootHostView {
    private var activityCommands: ActivityCommands {
        ActivityCommands(
            isRunOrchestratorAvailable: { dependencies.runOrchestrator != nil },
            submitManualRun: {
                try await dependencies.submitManualRun()
            },
            queueManualReload: { runID in
                queuedManualReload = .waitingForActive(runID)
            },
            reloadLibrary: { forceRefresh in
                await loadLibrary(forceRefresh: forceRefresh)
            },
            refreshActivityProjection: {
                await refreshActivityProjection()
            },
            runRecoveryPreflight: { runID in
                let outcome = await dependencies.runRecoveryPreflight(runID: runID)
                if case .resolved = outcome {
                    await refreshReportsProjection()
                }
                return outcome
            },
            currentFixPlanID: {
                fixPlanProjection.planID?.description
            }
        )
    }

    private var fixPlanCommands: FixPlanCommands {
        FixPlanCommands(
            fixPlanStore: dependencies.fixPlanStore,
            submitFixPlanWrite: { input in
                try await dependencies.submitFixPlanWrite(input: input)
            },
            ensureRecoveryHold: {
                await dependencies.ensureRecoveryHold()
            },
            refreshFixPlanProjection: {
                await refreshFixPlanOnly()
            },
            refreshActivityProjection: {
                await refreshActivityProjection()
            },
            now: { Date() }
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
        await runActivityCommand(.runManually())
    }

    private func acceptFixPlan() {
        guard let target = currentFixPlanTarget() else {
            setFixPlanNotice("Review plan is no longer available.", tone: .warning)
            return
        }
        runFixPlanCommand(.acceptFixPlan(target: target))
    }

    private func applyFixPlan() {
        guard let target = currentFixPlanTarget() else {
            setFixPlanNotice("Review plan is no longer available.", tone: .warning)
            return
        }
        runFixPlanCommand(.applyFixPlan(target: target))
    }

    private func rejectFixPlan() {
        guard let target = currentFixPlanTarget() else {
            setFixPlanNotice("Review plan is no longer available.", tone: .warning)
            return
        }
        runFixPlanCommand(.rejectFixPlan(target: target))
    }

    private func toggleFixPlanItem(_ itemID: String) {
        guard let target = currentFixPlanTarget(),
              let uuid = UUID(uuidString: itemID)
        else {
            setFixPlanNotice("Review item is no longer available.", tone: .warning)
            return
        }
        runFixPlanCommand(.togglePlanItem(uuid, target: target))
    }

    private func runFixPlanCommand(_ command: UserIntentCommand) {
        guard !isReviewBusy else {
            setFixPlanNotice("Review update is already in progress.", tone: .info)
            return
        }
        isReviewBusy = true
        clearFixPlanNotice()
        Task { @MainActor in
            defer { isReviewBusy = false }
            let result = await fixPlanCommands.handle(command)
            FixPlanCommands.showResult(result, handleResult: handleCommandResult) { notice in
                setFixPlanNotice(notice.message, tone: commandTone(for: notice.status))
            }
        }
    }

    private func commandTone(for status: CommandResultStatus) -> Tone {
        switch status {
        case .accepted:
            .success
        case .alreadyCovered,
             .navigated,
             .noOp,
             .queued:
            .info
        case .blockedByRecovery,
             .rejectedStale:
            .warning
        case .blockedByPermission,
             .rejectedInvalid,
             .requiresAttention,
             .temporaryUnavailable:
            .error
        }
    }

    private func currentFixPlanTarget() -> FixPlanCommandTarget? {
        guard fixPlanProjection.status == .ready,
              let planID = fixPlanProjection.planID,
              let planRevision = fixPlanProjection.planRevision,
              let decisionRevision = fixPlanProjection.decisionRevision
        else { return nil }

        return FixPlanCommandTarget(
            planID: planID,
            planRevision: planRevision,
            decisionRevision: decisionRevision,
            projectionRevision: fixPlanProjection.revision
        )
    }

    @discardableResult
    private func refreshFixPlanOnly() async -> FixPlanProjection {
        // FixPlanCommands refreshes activity after it classifies the command result.
        let projection = await dependencies.refreshFixPlanProjection()
        _ = applyFixPlanProjection(projection)
        return projection
    }
}

extension DesignRootHostView {
    private func applyNavigationTarget(_ target: CommandNavigationTarget?) {
        switch target {
        case .fixPlan:
            selectedRoute = .update
        case .recovery:
            selectedRoute = .update
            Task { @MainActor in
                _ = await workflowViewModel?.stopForRecoveryHold()
            }
        case .activity:
            selectedRoute = .activity
        case let .report(id):
            selectedRoute = .reports
            selectRunReport(id)
        case .settings:
            selectedRoute = .settings
        case nil:
            break
        }
    }
}

enum QueuedManualReload: Equatable {
    case waitingForActive(RunID)
    case waitingForQueued
}

struct QueuedReloadAdvance: Equatable {
    let next: QueuedManualReload?
    let shouldReload: Bool
}

func advanceQueuedReload(
    _ state: QueuedManualReload?,
    lifecycle: RunLifecycleSnapshot
) -> QueuedReloadAdvance {
    guard let state, lifecycle.finishedAt != nil else {
        return QueuedReloadAdvance(next: state, shouldReload: false)
    }

    switch state {
    case let .waitingForActive(runID) where lifecycle.runID == runID:
        return QueuedReloadAdvance(next: .waitingForQueued, shouldReload: false)
    case .waitingForActive, .waitingForQueued:
        return QueuedReloadAdvance(next: nil, shouldReload: true)
    }
}
