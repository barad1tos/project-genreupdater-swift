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
    let runLifecycle: RunLifecycleSnapshot?
    let settings: DesignSettingsSnapshot
    let now: Date
}

enum DesignActivitySnapshotAdapter {
    static let reportEntryLimit = 100

    static func makeSnapshot(
        from input: DesignActivitySnapshotInput,
        activityProjection: ActivityProjection,
        reportsProjection: ReportsProjection = .empty(),
        selectedRunReport: RunReportDetailSnapshot? = nil,
        activityNotice: String? = nil
    ) -> DesignDataSnapshot {
        let dashboard = makeDashboardSnapshot(from: input)
        let reportEntries = makeReportEntries(from: input.changeLogEntries)

        return DesignDataSnapshot(
            health: makeHealthSnapshot(from: dashboard, input: input),
            pipelineActivity: ActivityDesignAdapter.makePipelineSnapshot(
                from: activityProjection,
                notice: activityNotice
            ),
            pendingVerification: makePendingVerificationSnapshot(from: input.pendingVerification),
            coverage: makeCoverageBuckets(from: dashboard),
            issues: makeIssues(from: dashboard, input: input),
            metrics: makeMetricTiles(from: dashboard, input: input),
            activity: ActivityDesignAdapter.makeActivityItems(from: activityProjection),
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
            runHistory: ReportsProjectionDesignAdapter.makeRunHistory(from: reportsProjection),
            runHistorySkippedCount: reportsProjection.skippedCorruptedCount,
            selectedRunReport: selectedRunReport,
            settings: input.settings,
            syncStatusText: activityProjection.syncStatusText,
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
            // nil = metrics-backed snapshot without album identity; 0 = no cached metrics and no
            // live tracks (empty or not yet loaded).
            return input.metricsSnapshot == nil ? 0 : nil
        }

        return Set(input.tracks.map(\.albumIdentity)).count
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

    private static func makeAutomationState(from input: DesignActivitySnapshotInput) -> PipelineAutomationState {
        if input.isAutoSyncRunning {
            return .autoSyncRunning
        }

        if effectiveLastScanDate(from: input) != nil {
            return .manualScanOnly
        }

        return .noSyncYet
    }

    private static func makeNextRunLabel(
        automationState: PipelineAutomationState,
        input: DesignActivitySnapshotInput
    ) -> String {
        if let lifecycleLabel = makeRunLifecycleNextRunLabel(from: input.runLifecycle) {
            return lifecycleLabel
        }

        return automationState == .noSyncYet ? "Manual scan only" : automationState.stageDetail
    }

    private static func makeRunLifecycleNextRunLabel(from lifecycle: RunLifecycleSnapshot?) -> String? {
        guard let lifecycle else {
            return nil
        }

        switch lifecycle.phase {
        case .active:
            return lifecycle.trigger == .manualCheck ? "Manual sync running" : "Run in progress"
        case .finished(.failed, _):
            return lifecycle.trigger == .manualCheck ? "Manual sync failed" : "Run failed"
        case .finished(.completed, _), .finished(.completedNoOp, _):
            return nil
        }
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
}
