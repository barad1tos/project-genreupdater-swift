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
    @Environment(\.openSettings) private var openSettings

    @State private var hasStartedInitialLoad = false
    @State private var workflowViewModel: WorkflowViewModel?
    @State private var workflowNoticeMessage: String?
    @State private var selectedRoute: Route? = .activity
    @State private var activityProjection: ActivityProjection = .empty()
    @State private var reportsProjection: ReportsProjection = .empty()
    @State private var fixPlanProjection: FixPlanProjection = .empty()
    @State private var chromeProjection: ChromeProjection = .empty()
    @State private var browseProjection: BrowseProjection = .empty()
    @State private var browseDesignArtists: [DesignUI.Artist] = []
    @State private var browseDesignScope: DesignBrowseScope?
    @State private var browseRowIndex: [String: [BrowseTrackRow]] = [:]
    @State private var browseReadSource: BrowseReadSource = .cachedMirror(scannedAt: nil)
    @State private var browseNoticeMessage: String?
    @State private var artistCatalogFeed = ArtistCatalogFeed()
    @State private var analyticsSnapshot: DesignAnalyticsSnapshot = .empty
    @State private var analyticsWindow: DesignAnalyticsWindow = .currentSession
    @State private var selectedRunReport: RunReportDetailSnapshot?
    @State private var runReportDetailRequestID = UUID()
    @State private var activityCommandNoticeMessage: String?
    @State private var activityCommandNoticeID = UUID()
    @State private var fixPlanNoticeMessage: String?
    @State private var fixPlanNoticeTone: Tone = .info
    @State private var fixPlanNoticeID = UUID()
    @State private var isReviewBusy = false
    @State private var reportNotice: ReportNotice?
    @State private var reportNoticeID = UUID()
    @State private var isDismissalBusy = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("fastAnimations") private var fastAnimations = false
    @AppStorage(AppStorageKey.experienceLevel) private var experienceLevel: ExperienceLevel = .defaultLevel
    @AppStorage(AppStorageKey.settingsTab) private var settingsTab: SettingsTab = .general

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
            reportAnalyticsAccess: reportAnalyticsAccess,
            selectAnalyticsWindow: selectAnalyticsWindow,
            retryAnalytics: { Task { await refreshAnalytics() } },
            openAnalyticsSettings: openAnalyticsSettings,
            reportNotice: reportNotice,
            updateContent: { updateContent }
        )
        .task {
            await startInitialLoadIfNeeded()
            await refreshFixPlanProjection()
        }
        .task { await observeActivityProjectionUpdates() }
        .task { await observeReportsProjectionUpdates() }
        .task { await observeFixPlanUpdates() }
        .task { await observeChromeUpdates() }
        .task { await observeBrowseUpdates() }
        .task { await artistCatalogFeed.observe(dependencies.projectionStore) }
        .task(id: selectedRoute) { await observeAnalyticsUpdates() }
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
        .onChange(of: dependencies.isAutomationArmed) {
            scheduleActivityProjectionRefresh()
            // The toggle flips a chrome automation fact without crossing
            // any lifecycle or settings boundary.
            Task { await dependencies.refreshChromeProjection() }
        }
        .onChange(of: workflowDashboardState) {
            scheduleActivityProjectionRefresh()
            advanceQueuedReloadAfterWorkflowRun()
        }
        .onChange(of: workflowViewModel?.pendingVerificationReportSummary) {
            scheduleActivityProjectionRefresh()
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
            ),
            analytics: analyticsSnapshot
        )
    }

    private func selectAnalyticsWindow(_ window: DesignAnalyticsWindow) {
        analyticsWindow = window
        Task { await refreshAnalytics() }
    }

    private func refreshAnalytics() async {
        let requestToken = dependencies.analyticsReportGate.begin()
        let requestedWindow = analyticsWindow
        guard let recorder = dependencies.analyticsService else {
            guard dependencies.analyticsReportGate.isCurrent(requestToken) else { return }
            analyticsSnapshot = DesignAnalyticsSnapshot(
                state: .unavailable,
                selectedWindow: requestedWindow,
                summary: .empty,
                distribution: [],
                operations: [],
                recentEvents: []
            )
            return
        }
        let projection = await recorder.projection(
            for: AnalyticsSnapshotAdapter.serviceWindow(from: requestedWindow)
        )
        guard !Task.isCancelled, dependencies.analyticsReportGate.isCurrent(requestToken) else { return }
        analyticsSnapshot = AnalyticsSnapshotAdapter.makeSnapshot(from: projection)
    }

    private func observeAnalyticsUpdates() async {
        guard selectedRoute == .analytics, let recorder = dependencies.analyticsService else { return }
        await refreshAnalytics()
        var refreshTask: Task<Void, Never>?
        defer { refreshTask?.cancel() }
        for await _ in await recorder.updates() {
            guard !Task.isCancelled, selectedRoute == .analytics else { return }
            refreshTask?.cancel()
            refreshTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: AnalyticsRefreshPolicy.debounce)
                } catch {
                    return
                }
                guard selectedRoute == .analytics else { return }
                await refreshAnalytics()
            }
        }
    }

    private func openAnalyticsSettings() {
        settingsTab = .advanced
        openSettings()
    }

    private func observeChromeUpdates() async {
        for await projection in await dependencies.projectionStore.chromeUpdates() {
            guard projection.revision > chromeProjection.revision else { continue }
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

    /// Ordering and pairing guarantees live in the backend extension
    /// now; this wrapper keeps only the view-state application.
    private func refreshBrowseTruth(
        _ loadedTracks: [Core.Track],
        readSource: BrowseReadSource,
        loadToken: UInt64?
    ) async {
        browseReadSource = readSource
        let result = await dependencies.refreshBrowseProjection(
            tracks: loadedTracks,
            readSource: readSource,
            isCurrent: { loadToken.map(dependencies.libraryLoadGate.isCurrent) ?? true }
        )
        guard let result else { return }
        applyBrowseProjection(result.projection)
        if let rowIndex = result.rowIndex {
            browseRowIndex = rowIndex
        }
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
            await refreshBrowseTruth(dependencies.libraryTracks, readSource: browseReadSource, loadToken: nil)
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

    /// Adapter grouping of the dependency-graph library facts (F4/D1):
    /// the load chain is the sole writer; render and publish read the
    /// same live values.
    var currentActivityLibraryFacts: ActivityLibraryFacts {
        ActivityLibraryFacts(
            tracks: dependencies.libraryTracks,
            metricsSnapshot: dependencies.libraryMetrics,
            lastScanDate: dependencies.lastLibraryScanDate,
            loadError: dependencies.libraryLoadError,
            isLoading: dependencies.isLibraryLoading
        )
    }

    var currentActivityWorkflowFacts: ActivityWorkflowFacts {
        ActivityWorkflowFacts(
            dashboard: workflowDashboardState,
            pendingVerification: workflowViewModel?.pendingVerificationReportSummary
        )
    }

    private var designActivitySnapshotInput: DesignActivitySnapshotInput {
        DesignActivitySnapshotInput(
            library: currentActivityLibraryFacts,
            workflow: currentActivityWorkflowFacts,
            settings: settingsSnapshot,
            now: Date()
        )
    }

    @ViewBuilder
    private var updateContent: some View {
        if fixPlanProjection.status != .empty {
            UpdateResultView(
                snapshot: UpdateResultPreviewAdapter.makeSnapshot(
                    from: fixPlanProjection,
                    hasCleaningAccess: hasCleaningAccess,
                    noticeMessage: fixPlanNoticeMessage,
                    noticeTone: fixPlanNoticeTone
                ),
                onPrimaryAction: fixPlanPrimaryCallback,
                onToggleChange: fixPlanToggleCallback,
                onAcceptAll: fixPlanAcceptAllCallback,
                onRejectAll: fixPlanRejectAllCallback,
                onAccessAction: { openSettings() }
            )
        } else if let workflowViewModel {
            UpdateWorkflowView(
                viewModel: workflowViewModel,
                tracks: updateWorkflowTracks,
                testArtists: dependencies.config.development.testArtists,
                reportDisplayMode: dependencies.config.reporting.changeDisplayMode,
                credentialIssue: dependencies.discogsCredentialIssue,
                isLibraryReadyForUpdates: !dependencies.isLibraryLoading && dependencies.isLibraryReadyForUpdates,
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

    private var fixPlanPrimaryCallback: (() -> Void)? {
        guard !isReviewBusy, fixPlanProjection.canApply else { return nil }
        return { applyFixPlan() }
    }

    private var fixPlanToggleCallback: ((String) -> Void)? {
        guard !isReviewBusy else { return nil }
        return { toggleFixPlanItem($0) }
    }

    private var fixPlanAcceptAllCallback: (() -> Void)? {
        guard !isReviewBusy, fixPlanProjection.acceptedCount < fixPlanProjection.itemCount else { return nil }
        return { acceptFixPlan() }
    }

    private var fixPlanRejectAllCallback: (() -> Void)? {
        guard !isReviewBusy, fixPlanProjection.rejectedCount < fixPlanProjection.itemCount else { return nil }
        return { rejectFixPlan() }
    }

    private var hasCleaningAccess: Bool {
        _ = dependencies.subscriptionService?.currentTier
        return dependencies.featureGate?.canAccess(.artistAlbumCleaning) == true
    }

    private var reportAnalyticsAccess: ContentAccess {
        _ = dependencies.subscriptionService?.currentTier
        guard dependencies.featureGate?.canAccess(.reportsCharts) == true else {
            return .locked(
                message: "Aggregate report statistics and charts require Week Pass or Pro. "
                    + "Change log, run history, details, and recovery remain available."
            )
        }
        return .available
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
        // CONTRACT: the settings surface reads the synchronously-accepted
        // config, not the projection. These fields feed controlled
        // bindings and CAS-anchored mutations — the projection publishes
        // at the tail of the serialized apply queue, so reading it here
        // snapped pickers back and lost concurrent test-artist edits.
        // The projection serves cross-surface consumers.
        let configuration = dependencies.config
        return DesignSettingsSnapshot(
            updateBehavior: DesignUpdateBehavior(
                rawValue: configuration.processing.defaultUpdateBehavior.rawValue
            ) ?? .both,
            minimumConfidencePercent: configuration.yearRetrieval.logic.minConfidenceForNewYear,
            releaseYearRestoreThresholdYears: configuration.processing.releaseYearRestoreThreshold,
            artistScope: ArtistCatalogAdapter.makeScope(
                selected: configuration.development.testArtists,
                settingsRevision: configuration.revision,
                projection: artistCatalogFeed.projection
            ),
            presentation: DesignSettingsSnapshot.Presentation(
                appearanceMode: designAppearanceMode(from: appearanceMode),
                isFastAnimationsEnabled: fastAnimations,
                isAdvancedExperience: experienceLevel != .casual
            ),
            // Writes must always be verified before the app reports them as complete.
            isPostWriteVerificationRequired: true,
            discogsState: Self.discogsDisplayState(
                issue: dependencies.discogsCredentialIssue,
                isAccessAvailable: dependencies.isDiscogsAccessAvailable
            )
        )
    }

    /// The client factory is the sole no-token authority: it reports
    /// missingToken only after the resolved reference AND the Keychain
    /// fallback both come up empty. Testing the reference string here
    /// would misread a Keychain-only token as absent (and the raw
    /// reference defaults to a non-empty placeholder anyway).
    static func discogsDisplayState(
        issue: DiscogsCredentialIssue?,
        isAccessAvailable: Bool?
    ) -> DesignDiscogsState {
        if case .missingToken = issue {
            return .noToken
        }
        if issue != nil {
            return .tokenIssue
        }
        switch isAccessAvailable {
        case true: return .connected
        case false: return .tokenIssue
        default: return .unverified
        }
    }

    /// A finished load must refresh the mounted Update screen's scope
    /// preview, or an empty-to-populated load leaves the Start button
    /// dead until a mode change remounts it (was the live tail of the
    /// deleted reconcileUpdateScope).
    private func refreshWorkflowScopePreview() {
        guard let workflowViewModel, workflowViewModel.canStart else { return }
        workflowViewModel.computeScopePreview(tracks: updateWorkflowTracks)
    }

    private var updateWorkflowTracks: [Core.Track] {
        UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: dependencies.libraryTracks,
            testArtists: dependencies.config.development.testArtists,
            isLibraryReadyForUpdates: dependencies.isLibraryReadyForUpdates
        )
    }

    private func ensureWorkflowViewModel() {
        guard workflowViewModel == nil,
              let coordinator = dependencies.updateCoordinator,
              let pipeline = dependencies.changePreviewPipeline,
              let processor = dependencies.batchProcessor
        else { return }

        workflowViewModel = WorkflowViewModel(
            dependencies: dependencies.makeWorkflowDependencies(
                coordinator: coordinator,
                pipeline: pipeline,
                processor: processor
            ),
            defaults: WorkflowViewModel.Defaults(
                updateGenre: configuredUpdateSelection.updateGenre,
                updateYear: configuredUpdateSelection.updateYear,
                previewOnly: configuredPreviewOnly,
                minConfidence: configuredMinConfidence,
                releaseYearRestoreThreshold: dependencies.config.processing.releaseYearRestoreThreshold
            )
        )
        registerWorkflowFactsProvider()
        registerBatchRunProvider()
    }

    /// The orchestrator's batch runner reaches the LIVE view-model
    /// through this provider (D3); a dead one fails the run fast.
    private func registerBatchRunProvider() {
        let createdViewModel = workflowViewModel
        dependencies.batchRunProvider = { [weak createdViewModel] input, runID in
            guard let createdViewModel else {
                throw AppDependencyServiceError.batchRunnerUnavailable
            }
            return try await createdViewModel.performBatchRunWork(input: input, runID: runID)
        }
    }

    /// Every backend publish pulls workflow truth through this
    /// provider; a dead VM (closed window) reads as honest idle (A8).
    /// Legacy VM runs emit no lifecycle boundaries, so a reload queued
    /// during one (refused scope change) advances HERE when the VM
    /// leaves processing — the orchestrator-run path advances in the
    /// backend observer (publishLifecycleBoundary).
    private func advanceQueuedReloadAfterWorkflowRun() {
        guard dependencies.queuedManualReload == .waitingForQueued,
              workflowDashboardState.isProcessing == false,
              workflowViewModel?.canStart ?? true
        else { return }
        dependencies.queuedManualReload = nil
        Task { @MainActor in
            await dependencies.loadLibrary(forceRefresh: true)
        }
    }

    private func registerWorkflowFactsProvider() {
        let createdViewModel = workflowViewModel
        dependencies.workflowFactsProvider = { [weak createdViewModel] in
            ActivityWorkflowFacts(
                dashboard: createdViewModel?.dashboardState ?? .empty,
                pendingVerification: createdViewModel?.pendingVerificationReportSummary
            )
        }
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

    private func handleTestArtistScopeChange() {
        // Invalidate in-flight loads SYNCHRONOUSLY: their facts were
        // snapshotted under the old scope, and a late-starting refresh
        // would otherwise out-claim the emptied truth published below.
        dependencies.invalidateLibraryLoads()
        // The config change has already persisted (onChange fires after
        // commit) — browse truth empties in BOTH branches so the surface
        // never renders the previous scope, even while a run refuses the
        // reload.
        emptyBrowseTruthForScopeChange()

        guard workflowViewModel?.canStart ?? true else {
            workflowNoticeMessage = "The new test artist scope loads after the current update finishes."
            // The loaded library stays visible during the run; the new
            // scope loads when the run finishes (VM completion advances
            // the machine — legacy runs emit no lifecycle boundaries).
            if dependencies.queuedManualReload == nil {
                dependencies.queuedManualReload = .waitingForQueued
            }
            return
        }

        workflowNoticeMessage = nil
        browseNoticeMessage = nil
        dependencies.emptyLibraryTruthForScopeChange()
        workflowViewModel?.reset()
        applyWorkflowDefaults()

        Task { @MainActor in
            await refreshActivityProjection()
            await dependencies.loadLibrary(forceRefresh: true)
        }
    }

    private func emptyBrowseTruthForScopeChange() {
        Task { @MainActor in
            await refreshBrowseTruth([], readSource: browseReadSource, loadToken: nil)
        }
    }

    private func startInitialLoadIfNeeded() async {
        guard !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        // The chain delegates browse application (row-index pairing is
        // view state) and the scope-preview refresh back to the host.
        dependencies.applyBrowseTruthForLoad = { loadedTracks, readSource, token in
            await refreshBrowseTruth(loadedTracks, readSource: readSource, loadToken: token)
        }
        dependencies.onLibraryLoadApplied = { _ in
            refreshWorkflowScopePreview()
            Task { @MainActor in
                await dependencies.refreshArtistCatalog()
            }
        }
        ensureWorkflowViewModel()
        if await dependencies.ensureRecoveryHold() {
            _ = await workflowViewModel?.stopForRecoveryHold()
        }
        await dependencies.refreshArtistCatalog()
        await dependencies.loadLibrary()
        await refreshActivityProjection()
    }

    @discardableResult
    private func refreshActivityProjection() async -> ActivityProjection {
        // Workflow facts come through the registered provider — the
        // same freshness every backend publisher gets (A8).
        let storedProjection = await dependencies.republishActivityProjection()
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

    private func scheduleActivityProjectionRefresh() {
        Task { @MainActor in
            await refreshActivityProjection()
        }
    }

    @discardableResult
    private func refreshReportsProjection() async -> ReportsProjection? {
        guard let storedProjection = await dependencies.refreshReportsProjection() else { return nil }
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

    private func setTestArtists(_ change: ArtistScopeChange) -> ArtistScopeSaveResult {
        saveArtistScope(change, dependencies: dependencies)
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

extension AppDependencies {
    func makeWorkflowDependencies(
        coordinator: UpdateCoordinator,
        pipeline: ChangePreviewPipeline,
        processor: BatchProcessor
    ) -> WorkflowViewModel.Dependencies {
        WorkflowViewModel.Dependencies(
            updateCoordinator: coordinator,
            batchProcessor: processor,
            changePreviewPipeline: pipeline,
            pendingVerificationService: pendingVerificationService,
            featureGate: featureGate,
            runMaintenancePreflight: {
                await self.runMaintenancePreflight()
            },
            ensureRecoveryHold: {
                await self.ensureRecoveryHold()
            },
            clearRecovery: { id in
                try await self.clearRecoveryHold(id: id)
            },
            prepareMutationMetadata: { mutationTracks in
                _ = try await self.refreshTrackIDMappingOrThrow(
                    musicKitTracks: mutationTracks,
                    scopedArtists: self.config.development.testArtists,
                    mergeExisting: true
                )
            },
            resolveIncrementalTracks: { incrementalTracks, options in
                let lastRunTime = await self.incrementalRunTracker?.getLastRunTimestamp()
                return UpdateTrackScopeResolver.incrementalTracks(
                    incrementalTracks,
                    lastRunTime: lastRunTime,
                    previousTracks: self.previousIncrementalScopeTracks,
                    options: IncrementalTrackScopeOptions(
                        updateGenre: options.updateGenre,
                        genreMappings: self.config.cleaning.genreMappings
                    )
                )
            },
            invalidateAlbumYearCache: {
                await self.cacheService?.invalidateAllAlbumYears()
            },
            updateIncrementalRunTimestamp: {
                await self.incrementalRunTracker?.updateLastRunTimestamp()
                await self.refreshIncrementalRunTimestamp()
            },
            submitBatchRun: { input in
                try await self.submitBatchRun(input: input)
            },
            discardQueuedBatchRuns: {
                await self.runOrchestrator?.discardPendingBatchRuns()
            },
            problematicAlbumReportMinAttempts: {
                max(1, Int(self.config.reporting.minAttemptsForReport.rounded()))
            }
        )
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
                dependencies.queuedManualReload = .waitingForActive(runID)
            },
            reloadLibrary: { forceRefresh in
                await dependencies.loadLibrary(forceRefresh: forceRefresh)
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
        // Backend query-response (D6): assembly and active-run truth live
        // with the dependency graph; the host keeps only the result
        // behind its request-ID guard.
        let detail = await dependencies.loadRunReportDetail(runID: runID)
        guard runReportDetailRequestID == requestID else { return }

        guard let detail else {
            selectedRunReport = .unavailable(runID: runID)
            return
        }
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
