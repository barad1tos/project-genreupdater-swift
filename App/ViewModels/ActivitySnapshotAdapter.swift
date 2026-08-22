import Core
import DesignUI
import Foundation
import Services

/// One activity input per render truth (F4): the same fact values the
/// backend publish caches feed the design snapshot — no second read of
/// host state, no second Date().
struct DesignActivitySnapshotInput {
    let library: ActivityLibraryFacts
    let workflow: ActivityWorkflowFacts
    let settings: DesignSettingsSnapshot
    let now: Date
}

enum ActivitySnapshotAdapter {
    /// Mirrors the Chrome projection into DesignUI's shell snapshot —
    /// pure mapping, no derivation (ADR 0012).
    static func makeChrome(from projection: ChromeProjection) -> DesignChromeSnapshot {
        DesignChromeSnapshot(
            syncStatusText: projection.syncStatus.text,
            syncSeverity: makeSeverity(projection.syncStatus.severity),
            processingModeLabel: projection.safety.processingModeLabel,
            isAutoFixEnabled: !projection.safety.isPreviewMode,
            automationLabel: makeAutomationLabel(projection.safety.automationState),
            narrowedScopeLabel: projection.library.effectiveScope.flatMap { scope in
                guard scope.isNarrowedFromPhysical else { return nil }
                // The snapshot belongs to a run (ADR 0020); label it as
                // history unless that run is still active.
                return projection.syncStatus.isRunActive
                    ? scope.sourceLabel
                    : "Last run: \(scope.sourceLabel)"
            }
        )
    }

    private static func makeSeverity(_ severity: ChromeStatusSeverity) -> DesignChromeSeverity {
        switch severity {
        case .nominal: .nominal
        case .attention: .attention
        case .blocked: .blocked
        }
    }

    /// Mirrors the Browse projection into DesignUI's browse vocabulary —
    /// pure struct copies, no derivation: makeSnapshot re-runs on every
    /// body evaluation (ADR 0012).
    static func makeBrowseArtists(from projection: BrowseProjection) -> [DesignUI.Artist] {
        projection.artists.map { artist in
            DesignUI.Artist(
                id: artist.id,
                name: artist.name,
                albums: artist.albums.map(makeBrowseAlbum)
            )
        }
    }

    static func makeBrowseScope(from projection: BrowseProjection) -> DesignBrowseScope? {
        projection.scope.map { scope in
            DesignBrowseScope(
                sourceLabel: scope.summary.sourceLabel,
                detailLabel: scope.summary.detailLabel,
                isNarrowed: scope.summary.isNarrowedFromPhysical
            )
        }
    }

    static func makeBrowseRows(_ rows: [BrowseTrackRow]) -> [DesignBrowseTrackRow] {
        rows.map { row in
            DesignBrowseTrackRow(
                id: row.id,
                title: row.title,
                genre: row.genre,
                year: row.year,
                hasWriteIdentity: row.hasWriteIdentity,
                isInScope: row.isInScope
            )
        }
    }

    private static func makeBrowseAlbum(_ album: BrowseAlbumNode) -> DesignUI.Album {
        DesignUI.Album(
            id: album.id,
            name: album.title,
            artistName: album.artistName,
            genre: album.genre,
            year: album.year,
            counts: DesignBrowseCounts(
                tracks: album.counts.total,
                inScope: album.counts.inScope,
                writable: album.counts.writable
            ),
            action: DesignBrowseAction(
                title: album.action.title,
                isEnabled: album.action.isEnabled,
                disabledReason: album.action.disabledReason
            )
        )
    }

    private static func makeAutomationLabel(_ state: ChromeAutomationState) -> String {
        switch state {
        case .running: "Running"
        case .watching: "Watching library"
        case .scheduled: "Scheduled"
        case .manualOnly: "Manual trigger"
        case .nothingDue: "Nothing due"
        case .recoveryHold: "Recovery hold"
        case .permissionRequired: "Permission required"
        }
    }

    /// Browse pass-through grouped below the parameter ceiling.
    struct BrowseSnapshotInput {
        let artists: [DesignUI.Artist]
        let scope: DesignBrowseScope?

        static let empty = Self(artists: [], scope: nil)
    }

    static func makeSnapshot(
        from input: DesignActivitySnapshotInput,
        activityProjection: ActivityProjection,
        reportsProjection: ReportsProjection = .empty(),
        selectedRunReport: RunReportDetailSnapshot? = nil,
        activityNotice: String? = nil,
        chrome: DesignChromeSnapshot = .preview,
        browse: BrowseSnapshotInput = .empty,
        analytics: DesignAnalyticsSnapshot = .empty
    ) -> DesignDataSnapshot {
        let reportFacts = activityProjection.reportFacts

        return DesignDataSnapshot(
            health: makeHealthSnapshot(from: input, activityProjection: activityProjection),
            pipelineActivity: ActivityDesignAdapter.makePipelineSnapshot(
                from: activityProjection,
                notice: activityNotice
            ),
            pendingVerification: makePendingVerificationSnapshot(from: activityProjection.pendingVerification),
            coverage: makeCoverageBuckets(from: activityProjection.healthFacts),
            issues: makeIssues(from: activityProjection),
            metrics: makeMetricTiles(from: activityProjection.healthFacts, input: input),
            activity: ActivityDesignAdapter.makeActivityItems(from: activityProjection),
            artists: browse.artists,
            browseScope: browse.scope,
            // Change rows arrive with the reports lineage work, not browse.
            changes: [],
            dryRun: DryRunSummary(
                changes: input.workflow.dashboard.proposedChangeCount,
                // Paired with the SAME published totals the health card
                // shows — render-time track state may be a frame newer.
                tracks: activityProjection.healthFacts.counts.totalTracks,
                averageConfidence: 0,
                genre: 0,
                year: 0
            ),
            changeLog: makeChangeLog(from: reportFacts),
            reportStats: makeReportStats(from: reportFacts),
            genreDistribution: makeChartData(from: reportFacts.genreDistribution),
            updatesOverTime: makeChartData(from: reportFacts.updatesOverTime),
            yearDistribution: makeChartData(from: reportFacts.yearDistribution),
            runHistory: RunHistoryAdapter.makeRunHistory(from: reportsProjection),
            runHistorySkippedCount: reportsProjection.skippedCorruptedCount,
            selectedRunReport: selectedRunReport,
            settings: input.settings,
            syncStatusText: activityProjection.syncStatusText,
            chrome: chrome,
            isPreviewBacked: false,
            analytics: analytics
        )
    }

    /// Health numbers come from the published projection VERBATIM (S35):
    /// the builder owns the derivation, this adapter only formats.
    private static func makeHealthSnapshot(
        from input: DesignActivitySnapshotInput,
        activityProjection: ActivityProjection
    ) -> HealthSnapshot {
        let facts = activityProjection.healthFacts
        return HealthSnapshot(
            health: facts.healthScore,
            genre: facts.genreCoverageRatio,
            year: facts.yearCoverageRatio,
            consistency: facts.consistencyCoverageRatio,
            totalTracks: facts.counts.totalTracks,
            totalAlbums: activityProjection.scanFacts.albumCount,
            missingGenre: facts.missingGenreCount,
            missingYear: facts.missingYearCount,
            completeMetadata: facts.counts.tracksWithBoth,
            ready: facts.readyUpdateCount,
            pendingVerification: activityProjection.interventionCount,
            protectedFiles: facts.counts.isProtectedFileCountKnown ? facts.counts.protectedFileCount : nil,
            writeErrors: activityProjection.failedWriteCount,
            recentlyAdded: input.library.metricsSnapshot?.recentlyAdded ?? 0,
            lastScan: activityProjection.scanFacts.lastScanLabel,
            nextRun: activityProjection.scanFacts.nextRunLabel,
            source: "Apple Music · local files",
            library: "Music Library"
        )
    }

    private static func makeCoverageBuckets(from facts: ActivityHealthFacts) -> [CoverageBucket] {
        [
            CoverageBucket(
                id: "genre",
                label: "Genre coverage",
                ratio: facts.genreCoverageRatio,
                tone: makeCoverageTone(facts.genreCoverageRatio)
            ),
            CoverageBucket(
                id: "year",
                label: "Year coverage",
                ratio: facts.yearCoverageRatio,
                tone: makeCoverageTone(facts.yearCoverageRatio)
            ),
            CoverageBucket(
                id: "consistency",
                label: "Consistency",
                ratio: facts.consistencyCoverageRatio,
                tone: makeCoverageTone(facts.consistencyCoverageRatio)
            ),
            CoverageBucket(
                id: "editable",
                label: facts.counts.isProtectedFileCountKnown ? "Editable files" : "Editable files unknown",
                ratio: facts.editableCoverageRatio,
                tone: facts.counts.isProtectedFileCountKnown
                    ? makeCoverageTone(facts.editableCoverageRatio) : .neutral
            ),
        ]
    }

    private static func makeIssues(from projection: ActivityProjection) -> [Issue] {
        let facts = projection.healthFacts
        let failedWriteCount = projection.failedWriteCount
        return [
            makePendingVerificationIssue(projection.pendingVerification),
            Issue(
                id: "protected",
                label: facts.counts.isProtectedFileCountKnown ? "Protected files" : "Protected files unknown",
                count: facts.counts.protectedFileCount.formatted(),
                tone: makeProtectedTone(from: facts.counts),
                symbol: "lock"
            ),
            Issue(
                id: "errors",
                label: "Write errors",
                count: failedWriteCount.formatted(),
                tone: failedWriteCount > 0 ? .error : .success,
                symbol: failedWriteCount > 0 ? "xmark.octagon" : "checkmark.circle"
            ),
        ]
    }

    private static func makeMetricTiles(
        from facts: ActivityHealthFacts,
        input: DesignActivitySnapshotInput
    ) -> [MetricTile] {
        let missingGenreTrend = makeTrend(
            current: facts.missingGenreCount,
            previous: input.library.metricsSnapshot?.previousTracksNeedingGenre
        )
        let missingYearTrend = makeTrend(
            current: facts.missingYearCount,
            previous: input.library.metricsSnapshot?.previousTracksNeedingYear
        )

        return [
            MetricTile(
                id: "missing-genres",
                label: "Missing Genres",
                value: facts.missingGenreCount.formatted(),
                symbol: "tag.slash",
                tone: facts.missingGenreCount > 0 ? .warning : .success,
                trendUp: missingGenreTrend?.isUp,
                delta: missingGenreTrend?.delta
            ),
            MetricTile(
                id: "missing-years",
                label: "Missing Years",
                value: facts.missingYearCount.formatted(),
                symbol: "calendar.badge.exclamationmark",
                tone: facts.missingYearCount > 0 ? .info : .success,
                trendUp: missingYearTrend?.isUp,
                delta: missingYearTrend?.delta
            ),
            MetricTile(
                id: "complete-metadata",
                label: "Complete Metadata",
                value: facts.counts.tracksWithBoth.formatted(),
                symbol: "checkmark.seal",
                tone: makeCoverageTone(facts.consistencyCoverageRatio)
            )
        ]
    }

    private static func makePendingVerificationIssue(_ summary: ActivityPendingVerificationSummary?) -> Issue {
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
        from summary: ActivityPendingVerificationSummary?
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

    static func relativeElapsedLabel(since date: Date, now: Date) -> String {
        ActivityBuilder.relativeElapsedLabel(since: date, now: now)
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

    private static func makeProtectedTone(from counts: ActivityHealthCounts) -> Tone {
        guard counts.isProtectedFileCountKnown else {
            return .neutral
        }

        return counts.protectedFileCount > 0 ? .warning : .success
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
