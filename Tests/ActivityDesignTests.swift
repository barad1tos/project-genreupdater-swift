import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityDesign")
struct ActivityDesignTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("maps projection fields to pipeline snapshot")
    func mapsProjectionFieldsToPipelineSnapshot() throws {
        let projection = makeProjection()

        let snapshot = ActivityDesignAdapter.makePipelineSnapshot(from: projection)

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

    @Test("maps recovery command to resume action")
    func mapsRecoveryAction() {
        let projection = ActivityProjection(
            revision: .initial.advanced(),
            title: "Recovery needed",
            subtitle: "Previous run needs recovery before writes continue",
            syncStatusText: "Recovery needed",
            currentStage: .fix,
            processingMode: .preview,
            automationState: .manualScanOnly,
            deltaCount: 0,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: ActivityCommandDescriptor(
                id: "resume-recovery",
                title: "Resume safely",
                style: .primary,
                isEnabled: true,
                commandKind: .resumeRecovery
            ),
            secondaryCommand: nil,
            stageDescriptors: [],
            recentActivity: [],
            summaryCards: [],
            operationalIssues: []
        )

        let snapshot = ActivityDesignAdapter.makePipelineSnapshot(from: projection)

        #expect(snapshot.primaryAction.title == "Resume safely")
        #expect(snapshot.primaryAction.symbol == "shield.checkerboard")
        #expect(snapshot.primaryAction.style == .primary)
        #expect(snapshot.primaryAction.isEnabled)
    }

    @Test("notice overrides subtitle; nil notice keeps the projection subtitle")
    func noticeOverridesSubtitleAndNilNoticeKeepsProjectionSubtitle() {
        let projection = makeProjection(subtitle: "Projection subtitle")

        let withNotice = ActivityDesignAdapter.makePipelineSnapshot(
            from: projection,
            notice: "Custom notice"
        )
        let withoutNotice = ActivityDesignAdapter.makePipelineSnapshot(from: projection, notice: nil)

        #expect(withNotice.subtitle == "Custom notice")
        #expect(withoutNotice.subtitle == "Projection subtitle")
    }

    @Test("maps semantic delta detail from projection summary cards")
    func mapsSemanticDeltaDetailFromProjectionSummaryCards() {
        let projection = makeProjection(deltaDetail: "library changes")

        let snapshot = ActivityDesignAdapter.makePipelineSnapshot(from: projection)

        #expect(snapshot.deltaCount == 7)
        #expect(snapshot.deltaDetail == "library changes")
    }

    @Test("maps projection recent activity to activity items")
    func mapsProjectionRecentActivityToActivityItems() {
        let projection = makeProjection(recentActivity: [
            ActivityRecentItem(id: "scan", title: "Library scan", detail: "42 tracks analyzed"),
            ActivityRecentItem(id: "library-sync", title: "Library sync", detail: "7 library changes detected"),
        ])

        let items = ActivityDesignAdapter.makeActivityItems(from: projection)

        #expect(items.map(\.id) == ["scan", "library-sync"])
        #expect(items.first?.title == "Library scan")
        #expect(items.first?.detail == "42 tracks analyzed")
    }

    @Test("snapshot adapter sources activity owned fields from projection")
    func snapshotAdapterSourcesActivityOwnedFieldsFromProjection() {
        let firstProjection = makeProjection(
            title: "First pipeline",
            subtitle: "First subtitle",
            syncStatusText: "First sync",
            recentActivity: [
                ActivityRecentItem(id: "first", title: "First event", detail: "from Services"),
            ]
        )
        let secondProjection = makeProjection(
            title: "Second pipeline",
            subtitle: "Second subtitle",
            syncStatusText: "Second sync",
            recentActivity: [
                ActivityRecentItem(id: "second", title: "Second event", detail: "from Services"),
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
        let firstSnapshot = ActivitySnapshotAdapter.makeSnapshot(
            from: input,
            activityProjection: firstProjection
        )
        let secondSnapshot = ActivitySnapshotAdapter.makeSnapshot(
            from: input,
            activityProjection: secondProjection
        )

        #expect(firstSnapshot.pipelineActivity
            == ActivityDesignAdapter.makePipelineSnapshot(from: firstProjection))
        #expect(secondSnapshot.pipelineActivity
            == ActivityDesignAdapter.makePipelineSnapshot(from: secondProjection))
        #expect(firstSnapshot.activity == ActivityDesignAdapter.makeActivityItems(from: firstProjection))
        #expect(secondSnapshot.activity == ActivityDesignAdapter.makeActivityItems(from: secondProjection))
        #expect(firstSnapshot.syncStatusText == "First sync")
        #expect(secondSnapshot.syncStatusText == "Second sync")
        #expect(firstSnapshot.pipelineActivity != secondSnapshot.pipelineActivity)
        #expect(firstSnapshot.activity != secondSnapshot.activity)

        #expect(firstSnapshot.health == secondSnapshot.health)
        #expect(firstSnapshot.pendingVerification == secondSnapshot.pendingVerification)
        #expect(firstSnapshot.coverage == secondSnapshot.coverage)
        #expect(firstSnapshot.issues == secondSnapshot.issues)
        #expect(firstSnapshot.metrics == secondSnapshot.metrics)
        #expect(firstSnapshot.artists == secondSnapshot.artists)
        #expect(firstSnapshot.changes == secondSnapshot.changes)
        #expect(firstSnapshot.dryRun == secondSnapshot.dryRun)
        #expect(firstSnapshot.changeLog == secondSnapshot.changeLog)
        #expect(firstSnapshot.reportStats == secondSnapshot.reportStats)
        #expect(firstSnapshot.genreDistribution == secondSnapshot.genreDistribution)
        #expect(firstSnapshot.updatesOverTime == secondSnapshot.updatesOverTime)
        #expect(firstSnapshot.yearDistribution == secondSnapshot.yearDistribution)
        #expect(firstSnapshot.settings == secondSnapshot.settings)
        #expect(firstSnapshot.isPreviewBacked == secondSnapshot.isPreviewBacked)
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
            loadError: nil,
            isDryRun: true,
            workflow: workflow,
            pendingVerification: nil,
            changeLogEntries: [],
            isAutoSyncRunning: false,
            runLifecycle: nil,
            settings: .preview,
            now: now
        )
    }
}
