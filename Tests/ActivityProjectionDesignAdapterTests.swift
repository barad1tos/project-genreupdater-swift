import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityProjectionDesignAdapter")
struct ActivityProjectionDesignAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("maps projection fields to pipeline snapshot")
    func mapsProjectionFieldsToPipelineSnapshot() throws {
        let projection = makeProjection()

        let snapshot = ActivityProjectionDesignAdapter.makePipelineSnapshot(from: projection)

        #expect(snapshot.title == "Fix plan ready")
        #expect(snapshot.subtitle == "7 candidate fixes \u{00B7} preview mode \u{00B7} no Music tags written")
        #expect(snapshot.currentStage == .diff)
        #expect(snapshot.safetyMode == .preview)
        #expect(snapshot.automationState == .manualScanOnly)
        #expect(snapshot.deltaCount == 7)
        #expect(snapshot.deltaDetail == "candidate fixes")
        #expect(snapshot.interventionCount == 2)
        #expect(snapshot.protectedCount == 3)
        #expect(snapshot.failedWriteCount == 1)
        #expect(snapshot.primaryAction.title == "Review changes")
        #expect(snapshot.primaryAction.symbol == "checklist")
        #expect(snapshot.primaryAction.style == .primary)
        #expect(snapshot.primaryAction.isEnabled == false)

        let secondaryAction = try #require(snapshot.secondaryAction)
        #expect(secondaryAction.title == "Run manually")
        #expect(secondaryAction.isEnabled)
        #expect(secondaryAction.symbol == "arrow.clockwise")
        #expect(secondaryAction.style == .secondary)
        #expect(snapshot.status(for: .diff) == .current)
        #expect(snapshot.status(for: .fix) == .gated)
        #expect(snapshot.detail(for: .diff) == "Current delta")
    }

    @Test("maps semantic delta detail from projection summary cards")
    func mapsSemanticDeltaDetailFromProjectionSummaryCards() {
        let projection = makeProjection(deltaDetail: "library changes")

        let snapshot = ActivityProjectionDesignAdapter.makePipelineSnapshot(from: projection)

        #expect(snapshot.deltaCount == 7)
        #expect(snapshot.deltaDetail == "library changes")
    }

    @Test("maps projection recent activity to activity items")
    func mapsProjectionRecentActivityToActivityItems() {
        let projection = makeProjection(recentActivity: [
            ActivityRecentItem(id: "scan", title: "Library scan", detail: "42 tracks analyzed"),
            ActivityRecentItem(id: "library-sync", title: "Library sync", detail: "7 library changes detected"),
        ])

        let items = ActivityProjectionDesignAdapter.makeActivityItems(from: projection)

        #expect(items.map(\.id) == ["scan", "library-sync"])
        #expect(items.first?.title == "Library scan")
        #expect(items.first?.detail == "42 tracks analyzed")
    }

    @Test("snapshot adapter overrides only activity owned fields from projection")
    func snapshotAdapterOverridesActivityOwnedFieldsFromProjection() {
        let projection = makeProjection(
            title: "Projection pipeline",
            subtitle: "Projection subtitle",
            syncStatusText: "Projection sync",
            recentActivity: [
                ActivityRecentItem(id: "projection", title: "Projection event", detail: "from Services"),
            ]
        )
        let input = makeInput(tracks: [
            Core.Track(
                id: "1",
                name: "Tagged",
                artist: "Artist",
                album: "Album",
                genre: "Rock",
                year: 2001,
                trackStatus: "purchased"
            ),
        ])
        let baselineSnapshot = DesignActivitySnapshotAdapter.makeSnapshot(from: input)
        let projectedSnapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: input,
            activityProjection: projection
        )

        #expect(projectedSnapshot.pipelineActivity != baselineSnapshot.pipelineActivity)
        #expect(
            projectedSnapshot.pipelineActivity == ActivityProjectionDesignAdapter.makePipelineSnapshot(from: projection)
        )
        #expect(projectedSnapshot.activity != baselineSnapshot.activity)
        #expect(projectedSnapshot.activity == ActivityProjectionDesignAdapter.makeActivityItems(from: projection))
        #expect(projectedSnapshot.syncStatusText != baselineSnapshot.syncStatusText)
        #expect(projectedSnapshot.syncStatusText == "Projection sync")

        #expect(projectedSnapshot.health == baselineSnapshot.health)
        #expect(projectedSnapshot.pendingVerification == baselineSnapshot.pendingVerification)
        #expect(projectedSnapshot.coverage == baselineSnapshot.coverage)
        #expect(projectedSnapshot.issues == baselineSnapshot.issues)
        #expect(projectedSnapshot.metrics == baselineSnapshot.metrics)
        #expect(projectedSnapshot.artists == baselineSnapshot.artists)
        #expect(projectedSnapshot.changes == baselineSnapshot.changes)
        #expect(projectedSnapshot.dryRun == baselineSnapshot.dryRun)
        #expect(projectedSnapshot.changeLog == baselineSnapshot.changeLog)
        #expect(projectedSnapshot.reportStats == baselineSnapshot.reportStats)
        #expect(projectedSnapshot.genreDistribution == baselineSnapshot.genreDistribution)
        #expect(projectedSnapshot.updatesOverTime == baselineSnapshot.updatesOverTime)
        #expect(projectedSnapshot.yearDistribution == baselineSnapshot.yearDistribution)
        #expect(projectedSnapshot.settings == baselineSnapshot.settings)
        #expect(projectedSnapshot.isPreviewBacked == baselineSnapshot.isPreviewBacked)
    }

    private func makeProjection(
        title: String = "Fix plan ready",
        subtitle: String = "7 candidate fixes \u{00B7} preview mode \u{00B7} no Music tags written",
        syncStatusText: String = "Synced \u{00B7} 7 changes",
        deltaDetail: String = "candidate fixes",
        recentActivity: [ActivityRecentItem] = [
            ActivityRecentItem(id: "scan", title: "Library scan", detail: "42 tracks analyzed"),
        ]
    ) -> ActivityProjection {
        ActivityProjection(
            revision: .initial.advanced(),
            title: title,
            subtitle: subtitle,
            syncStatusText: syncStatusText,
            currentStage: .diff,
            processingMode: .preview,
            automationState: .manualScanOnly,
            deltaCount: 7,
            interventionCount: 2,
            protectedCount: 3,
            failedWriteCount: 1,
            isUndoReady: true,
            primaryCommand: nil,
            secondaryCommand: ActivityCommandDescriptor(
                id: "run-manually",
                title: "Run manually",
                style: .secondary,
                isEnabled: true,
                commandKind: .runManually
            ),
            stageDescriptors: [
                ActivityPipelineStageDescriptor(stage: .watch, detail: "Manual scan only", status: .completed),
                ActivityPipelineStageDescriptor(stage: .detect, detail: "Polling enabled", status: .completed),
                ActivityPipelineStageDescriptor(stage: .diff, detail: "Current delta", status: .current),
                ActivityPipelineStageDescriptor(stage: .fix, detail: "Preview gated", status: .gated),
                ActivityPipelineStageDescriptor(stage: .verify, detail: "Pending summary", status: .pending),
                ActivityPipelineStageDescriptor(stage: .report, detail: "Audit trail", status: .pending),
            ],
            recentActivity: recentActivity,
            summaryCards: [
                ActivitySummaryCard(
                    id: "delta",
                    kind: .delta,
                    label: "Delta",
                    value: "7",
                    detail: deltaDetail
                ),
            ],
            operationalIssues: []
        )
    }

    private func makeInput(
        tracks: [Core.Track] = [],
        metricsSnapshot: PersistedMetricsSnapshot? = nil,
        lastScanDate: Date? = nil,
        workflow: WorkflowDashboardState = .empty
    ) -> DesignActivitySnapshotInput {
        DesignActivitySnapshotInput(
            tracks: tracks,
            metricsSnapshot: metricsSnapshot,
            lastScanDate: lastScanDate,
            isLoading: false,
            isLibraryReadyForUpdates: true,
            loadError: nil,
            isDryRun: true,
            workflow: workflow,
            pendingVerification: nil,
            changeLogEntries: [],
            isSynchronizingLibrary: false,
            syncErrorMessage: nil,
            isLibrarySyncAvailable: true,
            isAutoSyncRunning: false,
            lastSyncResult: nil,
            settings: .preview,
            now: now
        )
    }
}
