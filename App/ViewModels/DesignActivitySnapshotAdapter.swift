import Core
import DesignUI
import Foundation
import Services

struct DesignActivitySnapshotInput {
    let tracks: [Core.Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let lastScanDate: Date?
    let isLoading: Bool
    let loadError: LibraryLoadError?
    let isDryRun: Bool
    let workflow: WorkflowDashboardState
    let pendingVerification: UpdateRunPendingVerificationSummary?
    let changeLogEntries: [Core.ChangeLogEntry]
    let isAutoSyncRunning: Bool
    let lastSyncResult: SyncResult?
    let now: Date
}

enum DesignActivitySnapshotAdapter {
    static let reportEntryLimit = 100

    static func makeSnapshot(from input: DesignActivitySnapshotInput) -> DesignDataSnapshot {
        let dashboard = makeDashboardSnapshot(from: input)
        let reportEntries = makeReportEntries(from: input.changeLogEntries)

        return DesignDataSnapshot(
            health: makeHealthSnapshot(from: dashboard, input: input),
            pipelineActivity: makePipelineSnapshot(from: dashboard, input: input),
            pendingVerification: makePendingVerificationSnapshot(from: input.pendingVerification),
            coverage: makeCoverageBuckets(from: dashboard),
            issues: makeIssues(from: dashboard, input: input),
            metrics: makeMetricTiles(from: dashboard, input: input),
            activity: makeActivityItems(from: dashboard, input: input),
            // Browse data stays empty until a dedicated bridge slice maps it from persisted/library sources.
            artists: [],
            changes: [],
            dryRun: DryRunSummary(
                changes: input.workflow.proposedChangeCount,
                tracks: 0,
                averageConfidence: 0,
                genre: 0,
                year: 0
            ),
            changeLog: makeChangeLog(from: reportEntries, now: input.now),
            reportStats: makeReportStats(from: reportEntries),
            genreDistribution: makeGenreDistribution(from: reportEntries),
            updatesOverTime: makeUpdatesOverTime(from: reportEntries),
            yearDistribution: makeYearDistribution(from: reportEntries),
            syncStatusText: makeSyncStatusText(from: input),
            isPreviewBacked: false
        )
    }

    private static func makeReportEntries(from entries: [Core.ChangeLogEntry]) -> [Core.ChangeLogEntry] {
        Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(reportEntryLimit))
    }

    private static func makeChangeLog(from entries: [Core.ChangeLogEntry], now: Date) -> [LogEntry] {
        entries.map { entry in
            LogEntry(
                id: entry.id.uuidString,
                time: relativeElapsedLabel(since: entry.timestamp, now: now),
                type: makeDesignChangeType(from: entry.changeType),
                track: makeChangeLogTrackTitle(from: entry),
                artist: entry.artist,
                old: makeChangeLogOldValue(from: entry),
                new: makeChangeLogNewValue(from: entry),
                conf: nil
            )
        }
    }

    private static func makeReportStats(from entries: [Core.ChangeLogEntry]) -> ReportStats {
        ReportStats(
            processed: entries.count,
            genres: entries.count { $0.newGenre != nil },
            years: entries.count { $0.newYear != nil }
        )
    }

    private static func makeGenreDistribution(from entries: [Core.ChangeLogEntry]) -> [ChartDatum] {
        let updatedGenres = entries.compactMap(\.newGenre)
        let genreCounts = Dictionary(grouping: updatedGenres, by: { $0 }).mapValues { $0.count }
        let sortedGenres = genreCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }

        return sortedGenres
            .prefix(8)
            .map { genre, count in
                ChartDatum(id: stableValueID(prefix: "genre", value: genre), label: genre, count: count)
            }
    }

    private static func makeUpdatesOverTime(from entries: [Core.ChangeLogEntry]) -> [ChartDatum] {
        let calendar = Calendar(identifier: .gregorian)
        let groupedByDay = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }

        return groupedByDay.keys.sorted().suffix(12).map { day in
            ChartDatum(
                id: "day-\(Int(day.timeIntervalSince1970))",
                label: day.formatted(.dateTime.month(.abbreviated).day()),
                count: groupedByDay[day]?.count ?? 0
            )
        }
    }

    private static func makeYearDistribution(from entries: [Core.ChangeLogEntry]) -> [ChartDatum] {
        let decadeCounts = Dictionary(grouping: entries.compactMap(\.newYear)) { year in
            year / 10 * 10
        }
        .mapValues(\.count)

        return decadeCounts.keys.sorted().map { decade in
            ChartDatum(
                id: "decade-\(decade)",
                label: "\(decade)s",
                count: decadeCounts[decade] ?? 0
            )
        }
    }

    private static func stableValueID(prefix: String, value: String) -> String {
        "\(prefix)-\(value.count)-\(value)"
    }

    private static func makeDesignChangeType(from changeType: Core.ChangeType) -> DesignUI.ChangeType {
        switch changeType {
        case .genreUpdate:
            .genre
        case .yearUpdate:
            .year
        case .trackCleaning:
            .track
        case .albumCleaning:
            .album
        case .artistRename:
            .artist
        case .yearRevert:
            .revert
        }
    }

    private static func makeChangeLogTrackTitle(from entry: Core.ChangeLogEntry) -> String {
        if !entry.trackName.isEmpty {
            return entry.trackName
        }

        if !entry.albumName.isEmpty {
            return entry.albumName
        }

        return entry.trackID
    }

    private static func makeChangeLogOldValue(from entry: Core.ChangeLogEntry) -> String {
        switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre ?? "none"
        case .yearUpdate, .yearRevert:
            entry.oldYear.map(String.init) ?? "none"
        case .trackCleaning:
            entry.oldTrackName ?? entry.trackName
        case .albumCleaning:
            entry.oldAlbumName ?? entry.albumName
        case .artistRename:
            entry.oldArtist ?? entry.artist
        }
    }

    private static func makeChangeLogNewValue(from entry: Core.ChangeLogEntry) -> String {
        switch entry.changeType {
        case .genreUpdate:
            entry.newGenre ?? "none"
        case .yearUpdate, .yearRevert:
            entry.newYear.map(String.init) ?? "none"
        case .trackCleaning:
            entry.newTrackName ?? entry.trackName
        case .albumCleaning:
            entry.newAlbumName ?? entry.albumName
        case .artistRename:
            entry.newArtist ?? entry.artist
        }
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
            missingGenre: dashboard.missingGenreCount,
            missingYear: dashboard.missingYearCount,
            completeMetadata: dashboard.tracksWithBoth,
            ready: dashboard.readyUpdateCount,
            pendingVerification: input.pendingVerification?.total ?? 0,
            protectedFiles: dashboard.protectedFileCount,
            writeErrors: input.workflow.failedWriteCount,
            recentlyAdded: input.metricsSnapshot?.recentlyAdded ?? 0,
            lastScan: makeLastScanLabel(from: input),
            nextRun: automationState == .noSyncYet ? "Manual scan only" : automationState.stageDetail,
            source: "Apple Music · local files",
            library: "Music Library"
        )
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
                style: .primary
            ),
            secondaryAction: PipelineAction(title: "Run manually", symbol: "arrow.clockwise", style: .secondary),
            stageStatuses: stageStatuses,
            stageDescriptors: makeStageDescriptors(
                stageStatuses: stageStatuses,
                automationState: automationState,
                input: input
            )
        )
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
            ),
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
            ),
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
            return "Scanning library"
        case .empty:
            return "Library empty"
        case .ready:
            break
        }

        if input.workflow.isProcessing {
            return input.workflow.phaseLabel
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
        switch dashboard.scanState {
        case .permissionDenied:
            return LibraryLoadError.permissionDenied.message
        case let .failed(message):
            return message
        case .loading:
            return input.isAutoSyncRunning ? "Auto-sync running · reading Music metadata" : "Manual scan in progress"
        case .empty:
            return "No Music tracks available for analysis"
        case .ready:
            break
        }

        if input.workflow.proposedChangeCount > 0 {
            let mode = input.isDryRun ? "preview mode · no Music tags written" : "write mode"
            return "\(input.workflow.proposedChangeCount.formatted()) candidate fixes · \(mode)"
        }

        return dashboard.primaryStatusText
    }

    private static func makeCurrentStage(
        from dashboard: LibraryDashboardSnapshot,
        input: DesignActivitySnapshotInput
    ) -> PipelineStage {
        switch dashboard.scanState {
        case .loading, .permissionDenied, .failed:
            return .detect
        case .empty:
            return .watch
        case .ready:
            break
        }

        if input.workflow.isProcessing || input.workflow.acceptedChangeCount > 0 {
            return .fix
        }

        if input.workflow.proposedChangeCount > 0 {
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

        switch dashboard.scanState {
        case .loading:
            statuses[.detect] = .current
        case .permissionDenied, .failed:
            statuses[.detect] = .failed
        case .empty:
            statuses[.detect] = .pending
        case .ready:
            statuses[.detect] = currentStage == .detect ? .current : .completed
        }

        if input.workflow.proposedChangeCount > 0 {
            statuses[.diff] = currentStage == .diff ? .current : .completed
        } else if currentStage == .detect {
            statuses[.diff] = .pending
        }

        if input.workflow.failedWriteCount > 0 {
            statuses[.fix] = .failed
        } else if input.workflow.isProcessing {
            statuses[.fix] = .current
        } else if input.workflow.proposedChangeCount > 0 || input.workflow.acceptedChangeCount > 0 {
            statuses[.fix] = input.isDryRun ? .gated : .pending
        }

        return statuses
    }

    private static func makeStageDescriptors(
        stageStatuses: [PipelineStage: PipelineStageStatus],
        automationState: PipelineAutomationState,
        input: DesignActivitySnapshotInput
    ) -> [PipelineStageDescriptor] {
        let detectDetail: String = input.isAutoSyncRunning ? "Polling enabled" : "Manual scan only"
        let diffDetail = input.workflow.proposedChangeCount > 0 ? "Current delta" : "No delta"
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
            PipelineStageDescriptor(stage: .report, detail: "Audit trail", status: stageStatuses[.report] ?? .pending),
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

    private static func makeSyncStatusText(from input: DesignActivitySnapshotInput) -> String {
        if input.isLoading {
            return "Scanning"
        }

        if let lastSyncResult = input.lastSyncResult {
            let changeCount = syncResultChangeCount(lastSyncResult)
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

    private static func relativeElapsedLabel(since date: Date, now: Date) -> String {
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
        let changeCount = syncResultChangeCount(result)
        return changeCount > 0 ? "\(changeCount.formatted()) library changes detected" : "No library changes detected"
    }

    private static func syncResultChangeCount(_ result: SyncResult) -> Int {
        result.newTracks.count
            + result.modifiedTracks.count
            + result.identityChangedTracks.count
            + result.refreshedTracks.count
            + result.removedTrackIDs.count
    }
}
