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
    @State private var selectedRoute: Route? = .activity
    @State private var activityProjection: ActivityProjection = .empty()
    @State private var queuedWriteSummary: ActivityQueuedWriteSummary?
    @State private var reportsProjection: ReportsProjection = .empty()
    @State private var fixPlanProjection: FixPlanProjection = .empty()
    @State private var chromeProjection: ChromeProjection = .empty()
    @State private var browseProjection: BrowseProjection = .empty()
    @State private var browseDesignArtists: [DesignUI.Artist] = []
    @State private var browseDesignScope: DesignBrowseScope?
    @State private var browseRowIndex: [String: [BrowseTrackRow]] = [:]
    @State private var browseReadSource: BrowseReadSource = .cachedMirror(scannedAt: nil)
    @State private var browseNoticeMessage: String?
    @State private var selectedRunReport: RunReportDetailSnapshot?
    @State private var runReportDetailRequestID = UUID()
    @State private var activityCommandNoticeMessage: String?
    @State private var activityCommandNoticeID = UUID()
    @State private var fixPlanNoticeMessage: String?
    @State private var fixPlanNoticeTone: Tone = .info
    @State private var fixPlanNoticeID = UUID()
    @State private var isReviewBusy = false
    @State private var queuedManualReload: QueuedManualReload?
    @State private var reportNotice: ReportNotice?
    @State private var reportNoticeID = UUID()
    @State private var isDismissalBusy = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("fastAnimations") private var fastAnimations = false
    @AppStorage(AppStorageKey.experienceLevel) private var experienceLevel: ExperienceLevel = .defaultLevel

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
            browseTrackRows: browseRows(for:),
            browseAlbumPreviewAction: performAlbumPreview(albumID:),
            browseNotice: browseNoticeMessage,
            reportRunSelectionAction: selectRunReport,
            recoveryDetailActions: RecoveryDetailActions(
                applyRemainingFixes: applyRemainingFixes,
                dismissItem: dismissRecoveryItem,
                dismissPreparedItems: dismissRecoveryItems
            ),
            reportNotice: reportNotice
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
        .task { await observeChromeUpdates() }
        .task { await observeBrowseUpdates() }
        .onChange(of: dependencies.config.processing.defaultUpdateBehavior) {
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
            // The toggle flips a chrome automation fact without crossing
            // any lifecycle or settings boundary.
            Task { await dependencies.refreshChromeProjection() }
        }
        .onChange(of: workflowDashboardState) {
            scheduleActivityProjectionRefresh()
        }
        .onChange(of: workflowViewModel?.pendingVerificationReportSummary) {
            scheduleActivityProjectionRefresh()
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
            activityNotice: activityCommandNoticeMessage,
            chrome: ActivitySnapshotAdapter.makeChrome(from: chromeProjection),
            browse: ActivitySnapshotAdapter.BrowseSnapshotInput(
                artists: browseDesignArtists,
                scope: browseDesignScope
            )
        )
    }

    private func observeChromeUpdates() async {
        for await projection in await dependencies.projectionStore.chromeUpdates() {
            chromeProjection = projection
        }
    }

    private func observeBrowseUpdates() async {
        for await projection in await dependencies.projectionStore.browseUpdates() {
            applyBrowseProjection(projection)
        }
    }

    /// Maps once per publish, never per body evaluation: makeSnapshot is
    /// a computed property and browse nodes number in the thousands.
    private func applyBrowseProjection(_ projection: BrowseProjection) {
        guard projection.revision > browseProjection.revision || browseDesignArtists.isEmpty else { return }
        browseProjection = projection
        browseDesignArtists = ActivitySnapshotAdapter.makeBrowseArtists(from: projection)
        browseDesignScope = ActivitySnapshotAdapter.makeBrowseScope(from: projection)
    }

    private func browseRows(for albumID: String) -> [DesignBrowseTrackRow] {
        ActivitySnapshotAdapter.makeBrowseRows(browseRowIndex[albumID] ?? [])
    }

    /// Publishes browse truth for one load. The generation is claimed
    /// BEFORE the input's awaits (facts are already snapshotted in the
    /// argument), the load guard re-checks after every await, and the
    /// row index only pairs with a projection this input actually
    /// produced — a losing publish keeps the winner's rows.
    private func refreshBrowseTruth(
        _ loadedTracks: [Core.Track],
        readSource: BrowseReadSource,
        requestID: UUID?
    ) async {
        browseReadSource = readSource
        let generation = await dependencies.claimBrowseInputGeneration()
        let input = await dependencies.makeBrowseInput(tracks: loadedTracks, readSource: readSource)
        if let requestID {
            guard isCurrentLibraryLoad(requestID) else { return }
        }
        let built = BrowseBuilder.makeProjection(input: input)
        let published = await dependencies.publishBrowseProjection(built, inputGeneration: generation)
        if let requestID {
            guard isCurrentLibraryLoad(requestID) else { return }
        }
        applyBrowseProjection(published)
        if browseContentMatches(published, built: built) {
            browseRowIndex = BrowseBuilder.makeTrackRowIndex(input: input)
        }
    }

    /// Whether the stored projection is the one this input produced —
    /// everything but the store-owned revision.
    private func browseContentMatches(_ published: BrowseProjection, built: BrowseProjection) -> Bool {
        published.artists == built.artists
            && published.scope == built.scope
            && published.physicalTrackCount == built.physicalTrackCount
            && published.readSource == built.readSource
            && published.operationalIssues == built.operationalIssues
    }

    /// Dispatches the typed preview command for one album. Revalidation
    /// happens in BrowseCommands against the CURRENT store truth; the
    /// target carries what the user was looking at (ADR 0011).
    private func performAlbumPreview(albumID: String) {
        let target = BrowseCommandTarget(
            albumID: albumID,
            projectionRevision: browseProjection.revision,
            scopeSnapshotID: browseProjection.scope?.snapshotID ?? UUID()
        )
        let commands = dependencies.makeBrowseCommands {
            await refreshBrowseTruth(tracks, readSource: browseReadSource, requestID: nil)
        }
        browseNoticeMessage = nil
        Task { @MainActor in
            let status = await commands.performAlbumPreview(target: target)
            switch status {
            case .accepted, .queued, .alreadyCovered:
                // The produced plan lands on the Update surface through
                // the existing lifecycle observer chain.
                selectedRoute = .update
            case .noOp,
                 .rejectedStale,
                 .rejectedInvalid,
                 .requiresAttention,
                 .blockedByRecovery,
                 .blockedByPermission,
                 .temporaryUnavailable,
                 .navigated:
                browseNoticeMessage = BrowseCommands.noticeCopy(for: status)
            }
        }
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
        dependencies.config.processing.defaultUpdateBehavior.enabledTargets
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
            updateBehavior: DesignUpdateBehavior(
                rawValue: dependencies.config.processing.defaultUpdateBehavior.rawValue
            ) ?? .both,
            minimumConfidencePercent: dependencies.config.yearRetrieval.logic.minConfidenceForNewYear,
            releaseYearRestoreThresholdYears: dependencies.config.processing.releaseYearRestoreThreshold,
            testArtists: ArtistAllowList.normalized(dependencies.config.development.testArtists),
            appearanceMode: designAppearanceMode(from: appearanceMode),
            isFastAnimationsEnabled: fastAnimations,
            // Writes must always be verified before the app reports them as complete.
            isPostWriteVerificationRequired: true,
            isAdvancedExperience: experienceLevel != .casual
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
            queuedWrite: queuedWriteSummary,
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

    private func selectRunReport(_ runID: String?) {
        if runID != selectedRunReport?.runID {
            clearReportNotice()
        }
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
        // Invalidate in-flight loads SYNCHRONOUSLY: their facts were
        // snapshotted under the old scope, and a late-starting refresh
        // would otherwise out-claim the emptied truth published below.
        libraryLoadRequestID = UUID()
        // The config change has already persisted (onChange fires after
        // commit) — browse truth empties in BOTH branches so the surface
        // never renders the previous scope, even while a run refuses the
        // reload.
        emptyBrowseTruthForScopeChange()

        guard workflowViewModel?.canStart ?? true else {
            workflowNoticeMessage = "Finish or reset the current update before reloading the new test artist scope."
            return
        }

        updateScopeTracks = nil
        workflowNoticeMessage = nil
        browseNoticeMessage = nil
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

    private func emptyBrowseTruthForScopeChange() {
        Task { @MainActor in
            await refreshBrowseTruth([], readSource: browseReadSource, requestID: nil)
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
        await refreshBrowseTruth(cachedLoad.tracks, readSource: .cachedMirror(scannedAt: nil), requestID: requestID)
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
        await refreshBrowseTruth(
            liveLoad.tracks,
            readSource: .liveLibrary(scannedAt: liveLoad.scanDate),
            requestID: requestID
        )
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
        queuedWriteSummary = await dependencies.queuedWriteSummary()
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
        var lastChromeRunID: RunID?
        var lastChromeState: RunLifecycleState?
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
            // House pattern until slice 10: chrome re-derives shell truth
            // at (run, state) boundaries. Per-item write checkpoints
            // re-emit the same state; skipping them keeps the probe cost
            // (file comparisons, workspace scan, count query) off the
            // write path where the projection could not change anyway.
            if lifecycle.runID != lastChromeRunID || lifecycle.state != lastChromeState {
                lastChromeRunID = lifecycle.runID
                lastChromeState = lifecycle.state
                await dependencies.refreshChromeProjection()
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

// MARK: - Settings command dispatch

extension DesignRootHostView {
    private func setDryRunMode(_ isDryRun: Bool) -> Bool {
        let didSave = mutateConfiguration(dependencies) { configuration in
            configuration.runtime.dryRun = isDryRun
        } == .accepted
        if didSave {
            applyWorkflowDefaults()
        }
        return didSave
    }

    private func setDefaultUpdateBehavior(_ behavior: DesignUpdateBehavior) -> Bool {
        let resolved = UpdateBehavior.resolved(from: behavior.rawValue)
        let didSave = mutateConfiguration(dependencies) { configuration in
            configuration.processing.defaultUpdateBehavior = resolved
        } == .accepted
        if didSave {
            applyWorkflowDefaults()
        }
        return didSave
    }

    private func setMinimumConfidence(_ percent: Double) -> Bool {
        let normalizedPercent = min(max(percent, 30), 100)
        return mutateConfiguration(dependencies) { configuration in
            configuration.yearRetrieval.logic.minConfidenceForNewYear = normalizedPercent
        } == .accepted
    }

    private func setReleaseYearRestoreThreshold(_ years: Int) -> Bool {
        let normalizedYears = min(max(years, 0), 100)
        return mutateConfiguration(dependencies) { configuration in
            configuration.processing.releaseYearRestoreThreshold = normalizedYears
        } == .accepted
    }

    private func setTestArtists(_ artists: [String]) -> Bool {
        let normalizedArtists = ArtistAllowList.normalized(artists)
        return mutateConfiguration(dependencies) { configuration in
            configuration.development.testArtists = normalizedArtists
        } == .accepted
    }

    private func setAppearanceMode(_ mode: DesignAppearanceMode) -> Bool {
        appearanceMode = appAppearanceMode(from: mode)
        return true
    }

    private func setFastAnimationsEnabled(_ isEnabled: Bool) -> Bool {
        fastAnimations = isEnabled
        return true
    }
}

extension DesignRootHostView {
    private var activityCommands: ActivityCommands {
        ActivityCommands(
            isRunOrchestratorAvailable: { dependencies.runOrchestrator != nil },
            submitManualRun: {
                try await dependencies.submitManualRun()
            },
            releaseQueuedWrite: {
                await dependencies.runOrchestrator?.releaseQueuedWrite() ?? .empty
            },
            dismissRecoveryWork: { runID, itemIDs, reason, isIndividual in
                try await dependencies.dismissRecoveryWork(
                    id: runID,
                    itemIDs: itemIDs,
                    reason: reason,
                    isIndividual: isIndividual
                )
                // Item states live in the reports projection; refresh it so
                // the dismissal is visible without an unrelated lifecycle
                // event. Chrome re-derives its hold fact the same way.
                await refreshReportsProjection()
                await dependencies.refreshChromeProjection()
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
                    await dependencies.refreshChromeProjection()
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
            loadRunRecord: { runID in
                try await dependencies.runRecordStore?.record(for: runID)
            },
            submitRunRequest: { request in
                guard let orchestrator = dependencies.runOrchestrator else {
                    throw AppDependencyServiceError.runOrchestratorUnavailable
                }
                return await orchestrator.submit(request)
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

    private func runFixPlanCommand(
        _ command: UserIntentCommand,
        showNotice: ((String, Tone) -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        let notify = showNotice ?? { setFixPlanNotice($0, tone: $1) }
        guard !isReviewBusy else {
            notify("Review update is already in progress.", .info)
            return
        }
        isReviewBusy = true
        // Clear only the surface that will carry this command's result.
        if showNotice == nil {
            clearFixPlanNotice()
        }
        Task { @MainActor in
            defer { isReviewBusy = false }
            let result = await fixPlanCommands.handle(command)
            FixPlanCommands.showResult(result, handleResult: handleCommandResult) { notice in
                notify(notice.message, commandTone(for: notice.status))
            }
            onFinished?()
        }
    }

    private func applyRemainingFixes(runID: String) {
        clearReportNotice()
        guard let sourceRunID = UUID(uuidString: runID) else {
            setReportNotice("Run report is no longer available.", tone: .warning, forRun: runID)
            return
        }
        guard let target = currentFixPlanTarget() else {
            setReportNotice("Review a plan before continuing.", tone: .warning, forRun: runID)
            return
        }
        runFixPlanCommand(
            .applyRemainingFixes(target: target, sourceRunID: sourceRunID),
            showNotice: { message, tone in setReportNotice(message, tone: tone, forRun: runID) },
            onFinished: { refreshSelectedRunReport(runID) }
        )
    }

    /// Renders only while the originating run is still selected — a result
    /// must never appear inside another run's card — and expires after the
    /// same 8s window as the sibling notice surfaces.
    private func setReportNotice(_ message: String, tone: Tone, forRun runID: String) {
        guard selectedRunReport?.runID == runID else { return }
        let noticeID = UUID()
        reportNoticeID = noticeID
        reportNotice = ReportNotice(message: message, tone: tone)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard reportNoticeID == noticeID else { return }
            clearReportNotice()
        }
    }

    private func clearReportNotice() {
        reportNoticeID = UUID()
        reportNotice = nil
    }

    /// Reload only while the same run is still selected: an unconditional
    /// reload would reopen a closed card or override a newer pick.
    private func refreshSelectedRunReport(_ runID: String) {
        guard selectedRunReport?.runID == runID else { return }
        selectRunReport(runID)
    }

    private func dismissRecoveryItem(runID: String, itemID: String, reason: String) {
        guard let command = ReportDetailAdapter.dismissItemCommand(
            runID: runID,
            itemID: itemID,
            reason: reason
        ) else {
            setReportNotice("Recovery item is no longer available.", tone: .warning, forRun: runID)
            return
        }
        runRecoveryDismissal(command, runID: runID)
    }

    private func dismissRecoveryItems(runID: String, itemIDs: [String], reason: String) {
        guard !itemIDs.isEmpty else { return }
        guard let command = ReportDetailAdapter.dismissPreparedItemsCommand(
            runID: runID,
            itemIDs: itemIDs,
            reason: reason
        ) else {
            setReportNotice("Recovery items are no longer available.", tone: .warning, forRun: runID)
            return
        }
        runRecoveryDismissal(command, runID: runID)
    }

    private func runRecoveryDismissal(_ command: UserIntentCommand, runID: String) {
        // One dismissal at a time: the store path is read-modify-write, so
        // interleaved commands could silently revert each other's outcome.
        guard !isDismissalBusy else {
            setReportNotice("Dismissal is already in progress.", tone: .info, forRun: runID)
            return
        }
        isDismissalBusy = true
        clearReportNotice()
        Task { @MainActor in
            defer { isDismissalBusy = false }
            let result = await activityCommands.handle(command)
            handleCommandResult(result, showsActivityNotice: false)
            setReportNotice(
                FixPlanCommands.noticeText(for: result),
                tone: commandTone(for: result.status),
                forRun: runID
            )
            refreshSelectedRunReport(runID)
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
    private func loadRunReportDetail(runID: String, requestID: UUID) async {
        let record = await dependencies.loadRunReportRecord(id: runID)
        guard runReportDetailRequestID == requestID else { return }

        guard let record else {
            selectedRunReport = .unavailable(runID: runID)
            return
        }
        let continuedBy = await dependencies.loadRunContinuations(id: runID)
        guard runReportDetailRequestID == requestID else { return }
        let detail = RunReportDetailBuilder.makeDetail(
            from: record,
            now: Date(),
            activeRunID: activeRunID,
            continuedBy: continuedBy
        )
        selectedRunReport = ReportDetailAdapter.makeSnapshot(from: detail)
    }

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
