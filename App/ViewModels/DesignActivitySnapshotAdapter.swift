import Core
import DesignUI
import Foundation
import Services

struct DesignActivitySnapshotInput {
    let tracks: [Core.Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let lastScanDate: Date?
    let isLoading: Bool
    let isLibraryReadyForUpdates: Bool
    let loadError: LibraryLoadError?
    let isDryRun: Bool
    let workflow: WorkflowDashboardState
    let pendingVerification: UpdateRunPendingVerificationSummary?
    let changeLogEntries: [Core.ChangeLogEntry]
    let isSynchronizingLibrary: Bool
    let syncErrorMessage: String?
    let isLibrarySyncAvailable: Bool
    let isAutoSyncRunning: Bool
    let lastSyncResult: SyncResult?
    let settings: DesignSettingsSnapshot
    let now: Date
}

enum DesignActivitySnapshotAdapter {
    static let reportEntryLimit = 100

    static func makeSnapshot(
        from input: DesignActivitySnapshotInput,
        activityProjection: ActivityProjection? = nil,
        activityNotice: String? = nil
    ) -> DesignDataSnapshot {
        let dashboard = makeDashboardSnapshot(from: input)
        let reportEntries = makeReportEntries(from: input.changeLogEntries)
        let pipelineActivity = if let activityProjection {
            ActivityProjectionDesignAdapter.makePipelineSnapshot(
                from: activityProjection,
                notice: activityNotice
            )
        } else {
            makePipelineSnapshot(from: dashboard, input: input)
        }
        let activity = if let activityProjection {
            ActivityProjectionDesignAdapter.makeActivityItems(from: activityProjection)
        } else {
            makeActivityItems(from: dashboard, input: input)
        }
        let syncStatusText = activityProjection?.syncStatusText ?? makeSyncStatusText(from: input)

        return DesignDataSnapshot(
            health: makeHealthSnapshot(from: dashboard, input: input),
            pipelineActivity: pipelineActivity,
            pendingVerification: makePendingVerificationSnapshot(from: input.pendingVerification),
            coverage: makeCoverageBuckets(from: dashboard),
            issues: makeIssues(from: dashboard, input: input),
            metrics: makeMetricTiles(from: dashboard, input: input),
            activity: activity,
            // Browse data stays empty until a dedicated bridge slice maps it from persisted/library sources.
            artists: [],
            changes: [],
            dryRun: DryRunSummary(
                changes: input.workflow.proposedChangeCount,
                tracks: input.tracks.count,
                averageConfidence: 0,
                genre: 0,
                year: 0
            ),
            changeLog: makeChangeLog(from: reportEntries, now: input.now),
            reportStats: makeReportStats(from: reportEntries),
            genreDistribution: makeGenreDistribution(from: reportEntries),
            updatesOverTime: makeUpdatesOverTime(from: reportEntries),
            yearDistribution: makeYearDistribution(from: reportEntries),
            settings: input.settings,
            syncStatusText: syncStatusText,
            isPreviewBacked: false
        )
    }

    private static func makeDashboardSnapshot(from input: DesignActivitySnapshotInput) -> LibraryDashboardSnapshot {
        if let metricsSnapshot = input.metricsSnapshot {
            return LibraryDashboardSnapshot.make(
                persistedMetrics: metricsSnapshot,
                isLoading: input.isLoading,
                loadError: input.loadError,
                isDryRun: input.isDryRun,
                workflow: input.workflow
            )
        }

        return LibraryDashboardSnapshot.make(
            tracks: input.tracks,
            lastScanDate: input.lastScanDate,
            isLoading: input.isLoading,
            loadError: input.loadError,
            isDryRun: input.isDryRun,
            workflow: input.workflow
        )
    }

    private static func makeHealthSnapshot(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> HealthSnapshot {
        let automationState = makeAutomationState(from: input)
        return HealthSnapshot(
            health: dashboard.healthScore,
            genre: dashboard.genreCoverageRatio,
            year: dashboard.yearCoverageRatio,
            consistency: dashboard.consistencyCoverageRatio,
            totalTracks: dashboard.totalTracks,
            totalAlbums: makeAlbumCount(from: input),
            missingGenre: dashboard.missingGenreCount,
            missingYear: dashboard.missingYearCount,
            completeMetadata: dashboard.tracksWithBoth,
            ready: dashboard.readyUpdateCount,
            pendingVerification: input.pendingVerification?.total ?? 0,
            protectedFiles: dashboard.protectedFileCount,
            writeErrors: input.workflow.failedWriteCount,
            recentlyAdded: input.metricsSnapshot?.recentlyAdded ?? 0,
            lastScan: makeLastScanLabel(from: input),
            nextRun: makeNextRunLabel(automationState: automationState, input: input),
            source: "Apple Music · local files",
            library: "Music Library"
        )
    }

    private static func makeAlbumCount(from input: DesignActivitySnapshotInput) -> Int? {
        guard !input.tracks.isEmpty else {
            // nil means unknown from cached metrics; 0 means a live empty library.
            return input.metricsSnapshot == nil ? 0 : nil
        }

        return Set(input.tracks.map(\.albumIdentity)).count
    }

    private static func makePipelineSnapshot(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> PipelineActivitySnapshot {
        let stageStatuses = makeStageStatuses(from: dashboard, input: input)
        let automationState = makeAutomationState(from: input)

        return PipelineActivitySnapshot(
            title: makePipelineTitle(from: dashboard, input: input),
            subtitle: makePipelineSubtitle(from: dashboard, input: input),
            currentStage: makeCurrentStage(from: dashboard, input: input),
            safetyMode: input.isDryRun ? .preview : .autoFix,
            automationState: automationState,
            deltaCount: input.workflow.proposedChangeCount,
            interventionCount: input.pendingVerification?.total ?? 0,
            protectedCount: dashboard.protectedFileCount,
            failedWriteCount: input.workflow.failedWriteCount,
            isUndoReady: false,
            primaryAction: PipelineAction(
                title: input.workflow.proposedChangeCount > 0 ? "Review fix plan" : dashboard.primaryActionTitle,
                symbol: input.workflow.proposedChangeCount > 0 ? "checklist" : "arrow.clockwise",
                style: .primary,
                isEnabled: isPrimaryActionEnabled(input: input)
            ),
            secondaryAction: PipelineAction(
                title: input.isSynchronizingLibrary ? "Syncing" : "Run manually",
                symbol: "arrow.clockwise",
                style: .secondary,
                isEnabled: !input.isSynchronizingLibrary && input.isLibrarySyncAvailable
            ),
            stageStatuses: stageStatuses,
            stageDescriptors: makeStageDescriptors(
                stageStatuses: stageStatuses,
                automationState: automationState,
                input: input
            )
        )
    }

    private static func isPrimaryActionEnabled(input: DesignActivitySnapshotInput) -> Bool {
        !input.isLoading
            && input.loadError == nil
            && input.isLibraryReadyForUpdates
            && !input.isSynchronizingLibrary
            && !input.workflow.isProcessing
    }

    private static func makeCoverageBuckets(from dashboard: LibraryDashboardSnapshot) -> [CoverageBucket] {
        dashboard.coverageBuckets.map { bucket in
            CoverageBucket(
                id: bucket.id,
                label: bucket.title,
                ratio: bucket.ratio,
                tone: bucket.title
                    .localizedCaseInsensitiveContains("unknown") ? .neutral : makeCoverageTone(bucket.ratio)
            )
        }
    }

    private static func makeIssues(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> [Issue] {
        [
            makePendingVerificationIssue(input.pendingVerification),
            Issue(
                id: "protected",
                label: dashboard.isProtectedFileCountKnown ? "Protected files" : "Protected files unknown",
                count: dashboard.protectedFileCount.formatted(),
                tone: makeProtectedTone(from: dashboard),
                symbol: "lock"
            ),
            Issue(
                id: "errors",
                label: "Write errors",
                count: input.workflow.failedWriteCount.formatted(),
                tone: input.workflow.failedWriteCount > 0 ? .error : .success,
                symbol: input.workflow.failedWriteCount > 0 ? "xmark.octagon" : "checkmark.circle"
            )
        ]
    }

    private static func makeMetricTiles(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> [MetricTile] {
        let missingGenreTrend = makeTrend(
            current: dashboard.missingGenreCount,
            previous: input.metricsSnapshot?.previousTracksNeedingGenre
        )
        let missingYearTrend = makeTrend(
            current: dashboard.missingYearCount,
            previous: input.metricsSnapshot?.previousTracksNeedingYear
        )

        return [
            MetricTile(
                id: "missing-genres",
                label: "Missing Genres",
                value: dashboard.missingGenreCount.formatted(),
                symbol: "tag.slash",
                tone: dashboard.missingGenreCount > 0 ? .warning : .success,
                trendUp: missingGenreTrend?.isUp,
                delta: missingGenreTrend?.delta
            ),
            MetricTile(
                id: "missing-years",
                label: "Missing Years",
                value: dashboard.missingYearCount.formatted(),
                symbol: "calendar.badge.exclamationmark",
                tone: dashboard.missingYearCount > 0 ? .info : .success,
                trendUp: missingYearTrend?.isUp,
                delta: missingYearTrend?.delta
            ),
            MetricTile(
                id: "complete-metadata",
                label: "Complete Metadata",
                value: dashboard.tracksWithBoth.formatted(),
                symbol: "checkmark.seal",
                tone: makeCoverageTone(dashboard.consistencyCoverageRatio)
            )
        ]
    }

    private static func makeActivityItems(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> [ActivityItem] {
        var items = dashboard.recentActivity.map { item in
            ActivityItem(id: item.id, title: item.title, detail: item.detail)
        }

        if let pendingVerification = input.pendingVerification {
            items.append(
                ActivityItem(
                    id: "pending-verification",
                    title: "Pending verification",
                    detail: "\(pendingVerification.total.formatted()) albums queued, \(pendingVerification.due.formatted()) due"
                )
            )
        }

        if let lastSyncResult = input.lastSyncResult {
            items.append(
                ActivityItem(
                    id: "library-sync",
                    title: "Library sync",
                    detail: syncResultDetail(lastSyncResult)
                )
            )
        }

        if let syncErrorMessage = input.syncErrorMessage {
            items.append(
                ActivityItem(
                    id: "library-sync-error",
                    title: "Library sync failed",
                    detail: syncErrorMessage
                )
            )
        }

        if input.isDryRun {
            items.append(ActivityItem(id: "preview-mode", title: "Preview mode", detail: "no tags written to Music"))
        }

        return items
    }

    private static func makePendingVerificationIssue(_ summary: UpdateRunPendingVerificationSummary?) -> Issue {
        guard let summary else {
            return Issue(
                id: "pending",
                label: "Pending verification",
                count: "Unavailable",
                tone: .neutral,
                symbol: "eye",
                route: .update
            )
        }

        return Issue(
            id: "pending",
            label: "Pending verification",
            count: summary.total.formatted(),
            unit: "albums",
            tone: summary.total > 0 ? .purple : .success,
            symbol: "eye",
            route: .update
        )
    }

    private static func makePendingVerificationSnapshot(
        from summary: UpdateRunPendingVerificationSummary?
    ) -> PendingVerificationSnapshot {
        guard let summary else {
            return .unavailable
        }

        return PendingVerificationSnapshot(
            totalAlbums: summary.total,
            dueAlbums: summary.due,
            skippedByInterval: summary.skippedByInterval,
            problematicAlbums: summary.problematic,
            verifiedAlbums: summary.verified
        )
    }

    private static func makePipelineTitle(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> String {
        switch dashboard.scanState {
        case .failed, .permissionDenied:
            return "Library needs attention"
        case .loading:
            if !input.isSynchronizingLibrary {
                return "Scanning library"
            }
        case .empty:
            if !hasSyncState(input) {
                return "Library empty"
            }
        case .ready:
            break
        }

        if input.workflow.isProcessing {
            return input.workflow.phaseLabel
        }

        if input.isSynchronizingLibrary {
            return "Syncing library"
        }

        if input.syncErrorMessage != nil {
            return "Sync needs attention"
        }

        if input.workflow.proposedChangeCount > 0 {
            return "Fix plan ready"
        }

        return "Library ready"
    }

    private static func makePipelineSubtitle(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> String {
        if let scanSubtitle = makeScanSubtitle(from: dashboard.scanState, input: input) {
            return scanSubtitle
        }

        if input.isSynchronizingLibrary {
            return "Manual sync running · detecting library delta"
        }

        if let syncErrorMessage = input.syncErrorMessage {
            return syncErrorMessage
        }

        if input.workflow.proposedChangeCount > 0 {
            let mode = input.isDryRun ? "preview mode · no Music tags written" : "write mode"
            return "\(input.workflow.proposedChangeCount.formatted()) candidate fixes · \(mode)"
        }

        if let lastSyncResult = input.lastSyncResult {
            return syncResultDetail(lastSyncResult)
        }

        return dashboard.primaryStatusText
    }

    private static func makeScanSubtitle(
        from scanState: LibraryScanState,
        input: DesignActivitySnapshotInput
    ) -> String? {
        switch scanState {
        case .permissionDenied:
            LibraryLoadError.permissionDenied.message
        case let .failed(message):
            message
        case .loading:
            input.isSynchronizingLibrary ? nil : makeLoadingSubtitle(isAutoSyncRunning: input.isAutoSyncRunning)
        case .empty:
            hasSyncState(input) ? nil : "No Music tracks available for analysis"
        case .ready:
            nil
        }
    }

    private static func makeLoadingSubtitle(isAutoSyncRunning: Bool) -> String {
        isAutoSyncRunning ? "Auto-sync running · reading Music metadata" : "Manual scan in progress"
    }

    private static func makeCurrentStage(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> PipelineStage {
        switch dashboard.scanState {
        case .loading, .permissionDenied, .failed:
            return .detect
        case .empty:
            if !hasSyncState(input) {
                return .watch
            }
        case .ready:
            break
        }

        if input.workflow.isProcessing || input.workflow.acceptedChangeCount > 0 {
            return .fix
        }

        if input.isSynchronizingLibrary || input.syncErrorMessage != nil {
            return .detect
        }

        if input.workflow.proposedChangeCount > 0 {
            return .diff
        }

        if input.lastSyncResult != nil {
            return .diff
        }

        return input.isAutoSyncRunning ? .watch : .detect
    }

    private static func makeStageStatuses(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> [PipelineStage: PipelineStageStatus] {
        let currentStage = makeCurrentStage(from: dashboard, input: input)
        var statuses = Dictionary(uniqueKeysWithValues: PipelineStage.allCases
            .map { ($0, PipelineStageStatus.pending) })

        statuses[.watch] = currentStage == .watch ? .current : .completed

        statuses[.detect] = makeDetectStageStatus(
            scanState: dashboard.scanState,
            currentStage: currentStage,
            input: input
        )
        statuses[.diff] = makeDiffStageStatus(currentStage: currentStage, input: input)
        if let fixStatus = makeFixStageStatus(input: input) {
            statuses[.fix] = fixStatus
        }

        return statuses
    }

    private static func makeDetectStageStatus(
        scanState: LibraryScanState,
        currentStage: PipelineStage,
        input: DesignActivitySnapshotInput
    ) -> PipelineStageStatus {
        if input.isSynchronizingLibrary {
            return .current
        }

        if input.syncErrorMessage != nil {
            return .failed
        }

        if input.lastSyncResult != nil {
            return currentStage == .detect ? .current : .completed
        }

        switch scanState {
        case .loading:
            return .current
        case .permissionDenied, .failed:
            return .failed
        case .empty:
            return .pending
        case .ready:
            return currentStage == .detect ? .current : .completed
        }
    }

    private static func makeDiffStageStatus(
        currentStage: PipelineStage,
        input: DesignActivitySnapshotInput
    ) -> PipelineStageStatus {
        if input.workflow.proposedChangeCount > 0 || input.lastSyncResult != nil {
            return currentStage == .diff ? .current : .completed
        }

        return .pending
    }

    private static func makeFixStageStatus(input: DesignActivitySnapshotInput) -> PipelineStageStatus? {
        if input.workflow.failedWriteCount > 0 {
            return .failed
        }

        if input.workflow.isProcessing {
            return .current
        }

        if input.workflow.proposedChangeCount > 0 || input.workflow.acceptedChangeCount > 0 {
            return input.isDryRun ? .gated : .pending
        }

        return nil
    }

    private static func makeStageDescriptors(
        stageStatuses: [PipelineStage: PipelineStageStatus],
        automationState: PipelineAutomationState,
        input: DesignActivitySnapshotInput
    ) -> [PipelineStageDescriptor] {
        let detectDetail = if input.isSynchronizingLibrary {
            "Detecting delta"
        } else if input.syncErrorMessage != nil {
            "Sync failed"
        } else if input.isAutoSyncRunning {
            "Periodic polling"
        } else {
            "Manual trigger"
        }
        let diffDetail = makeDiffDetail(from: input)
        let fixDetail = input.isDryRun ? "Preview gated" : "Write mode"
        let verifyDetail = input.pendingVerification == nil ? "Not available" : "Pending summary"

        return [
            PipelineStageDescriptor(
                stage: .watch,
                detail: automationState.stageDetail,
                status: stageStatuses[.watch] ?? .pending
            ),
            PipelineStageDescriptor(stage: .detect, detail: detectDetail, status: stageStatuses[.detect] ?? .pending),
            PipelineStageDescriptor(stage: .diff, detail: diffDetail, status: stageStatuses[.diff] ?? .pending),
            PipelineStageDescriptor(stage: .fix, detail: fixDetail, status: stageStatuses[.fix] ?? .pending),
            PipelineStageDescriptor(stage: .verify, detail: verifyDetail, status: stageStatuses[.verify] ?? .pending),
            PipelineStageDescriptor(stage: .report, detail: "Audit trail", status: stageStatuses[.report] ?? .pending)
        ]
    }

    private static func makeAutomationState(from input: DesignActivitySnapshotInput) -> PipelineAutomationState {
        if input.isAutoSyncRunning {
            return .autoSyncRunning
        }

        if effectiveLastScanDate(from: input) != nil {
            return .manualScanOnly
        }

        return .noSyncYet
    }

    private static func hasSyncState(_ input: DesignActivitySnapshotInput) -> Bool {
        input.isSynchronizingLibrary || input.syncErrorMessage != nil || input.lastSyncResult != nil
    }

    private static func makeNextRunLabel(
        automationState: PipelineAutomationState,
        input: DesignActivitySnapshotInput
    ) -> String {
        if input.isSynchronizingLibrary {
            return "Manual sync running"
        }

        if input.syncErrorMessage != nil {
            return "Manual sync failed"
        }

        return automationState == .noSyncYet ? "Manual scan only" : automationState.stageDetail
    }

    private static func makeSyncStatusText(from input: DesignActivitySnapshotInput) -> String {
        if input.isSynchronizingLibrary {
            return "Syncing"
        }

        if input.syncErrorMessage != nil {
            return "Sync failed"
        }

        if input.isLoading {
            return "Scanning"
        }

        if let lastSyncResult = input.lastSyncResult {
            let changeCount = lastSyncResult.changeCount
            return changeCount > 0 ? "Synced · \(changeCount.formatted()) changes" : "Synced · no changes"
        }

        if let lastScanDate = effectiveLastScanDate(from: input) {
            return "Synced \(relativeElapsedLabel(since: lastScanDate, now: input.now))"
        }

        return input.isAutoSyncRunning ? "Auto-sync running" : "No sync yet"
    }

    private static func makeLastScanLabel(from input: DesignActivitySnapshotInput) -> String {
        guard let lastScanDate = effectiveLastScanDate(from: input) else {
            return "No scan yet"
        }

        return relativeElapsedLabel(since: lastScanDate, now: input.now)
    }

    private static func effectiveLastScanDate(from input: DesignActivitySnapshotInput) -> Date? {
        input.metricsSnapshot?.timestamp ?? input.lastScanDate
    }

    static func relativeElapsedLabel(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))

        if seconds < 60 {
            return "just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        let days = hours / 24
        return "\(days)d ago"
    }

    private static func makeCoverageTone(_ ratio: Double) -> Tone {
        if ratio >= 0.9 {
            return .success
        }

        if ratio >= 0.6 {
            return .warning
        }

        return .error
    }

    private static func makeProtectedTone(from dashboard: LibraryDashboardSnapshot) -> Tone {
        guard dashboard.isProtectedFileCountKnown else {
            return .neutral
        }

        return dashboard.protectedFileCount > 0 ? .warning : .success
    }

    private static func makeTrend(current: Int, previous: Int?) -> (isUp: Bool, delta: String)? {
        guard let previous, previous > 0 else {
            return nil
        }

        let delta = current - previous
        guard delta != 0 else {
            return nil
        }

        return (delta > 0, abs(delta).formatted())
    }

    private static func syncResultDetail(_ result: SyncResult) -> String {
        let changeCount = result.changeCount
        return changeCount > 0 ? "\(changeCount.formatted()) library changes detected" : "No library changes detected"
    }

    private static func makeDiffDetail(from input: DesignActivitySnapshotInput) -> String {
        if input.workflow.proposedChangeCount > 0 {
            return "Current delta"
        }

        guard let lastSyncResult = input.lastSyncResult else {
            return "No delta"
        }

        let changeCount = lastSyncResult.changeCount
        return changeCount > 0 ? "\(changeCount.formatted()) library changes" : "No library delta"
    }
}
