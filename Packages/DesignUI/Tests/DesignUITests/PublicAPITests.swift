import DesignUI
import SwiftUI
import Testing

@Suite("DesignUI public data contract")
struct PublicAPITests {
    @Test
    func constructsPublicResultModels() {
        let change = UpdateResultChange(
            id: "change",
            type: .genre,
            oldValue: "Electronic",
            newValue: "Art Pop",
            source: "Discogs",
            confidence: 0.94,
            state: .proposed(.accepted)
        )
        let detail = UpdateResultDetail(id: "technical-id", label: "Technical ID", value: "track")
        let track = UpdateResultTrack(
            id: "track",
            title: "Jóga",
            artist: "Björk",
            state: .ready,
            changes: [change],
            details: [detail]
        )
        let album = UpdateResultAlbum(id: "album", title: "Björk — Homogenic", tracks: [track])
        let metric = UpdateResultMetric(id: "changes", label: "Changes", value: "1", tone: .accent)
        let notice = UpdateResultNotice(id: "notice", title: "Ready", message: "One change", tone: .info)
        let snapshot = UpdateResultSnapshot(
            mode: .preview,
            status: .ready,
            title: "Update results",
            subtitle: "Review metadata changes",
            scope: "Test artists",
            metrics: [metric],
            albums: [album],
            notices: [notice],
            contentAccess: .locked(message: "Week Pass or Pro required"),
            primaryActionLabel: "Apply",
            secondaryActionLabel: "Reject all",
            secondaryActionIcon: "xmark.circle",
            details: [detail]
        )
        let modes: [UpdateResultMode] = [.preview, .write]
        let statuses: [UpdateResultStatus] = [
            .empty, .ready, .stale, .unavailable, .completed, .completedWithFailures,
        ]
        let sections: [UpdateResultSection] = [.status, .metrics, .albums, .details, .actions]
        let verdicts: [UpdateResultVerdict] = [.accepted, .rejected]
        let changeStates: [UpdateResultChangeState] = [
            .proposed(.rejected), .applied, .noChange, .skipped, .failed(message: "Write failed"),
        ]
        let trackStates: [UpdateResultTrackState] = [
            .ready, .applied, .noChange, .skipped, .failed(message: "Write failed"),
        ]

        #expect(snapshot.albums == [album])
        #expect(snapshot.metrics == [metric])
        #expect(snapshot.notices == [notice])
        #expect(snapshot.details == [detail] && snapshot.secondaryActionIcon == "xmark.circle")
        #expect(snapshot.albums.first?.tracks.first?.details == [detail])
        #expect(snapshot.affectedTrackCount == 1)
        #expect(modes.count == 2)
        #expect(statuses.count == 6)
        #expect(sections == snapshot.sections)
        #expect(verdicts.count == 2)
        #expect(changeStates.count == 5)
        #expect(trackStates.count == 5)
    }

    @Test
    @MainActor
    func snapshotCanBeConstructedOutsideDesignUIModule() {
        let data = makeSnapshot(totalTracks: 10, syncStatusText: "No sync yet", deltaCount: 2)
        let model = AppModel(data: data)
        let root = RootView(data: data, reportNotice: nil) {
            EmptyView()
        }
        let availableReportsRoot = RootView(
            data: data,
            reportAnalyticsAccess: .available,
            reportNotice: nil
        ) {
            EmptyView()
        }
        let lockedReportsRoot = RootView(
            data: data,
            reportAnalyticsAccess: .locked(message: "Week Pass or Pro required"),
            reportNotice: nil
        ) {
            EmptyView()
        }
        let actionRoot = RootView(
            data: data,
            pipelinePrimaryAction: {
                _ = data.pipelineActivity.primaryAction.title
            },
            pipelineSecondaryAction: { action in
                _ = action.title
            },
            setUpdateBehaviorAction: { $0 == .both },
            setMinimumConfidenceAction: { $0 >= 0 },
            setReleaseYearRestoreThresholdAction: { $0 >= 0 },
            reportNotice: ReportNotice(message: "Dismissed 2 items", tone: .success),
            updateContent: {
                EmptyView()
            }
        )

        #expect(data.health.totalTracks == 10)
        #expect(data.pipelineActivity.deltaCount == 2)
        #expect(data.pendingVerification.totalAlbums == 2)
        #expect(data.syncStatusText == "No sync yet")
        #expect(model.snapshot.totalTracks == 10)
        #expect(model.pipelineActivity.deltaCount == 2)
        _ = root
        _ = availableReportsRoot
        _ = lockedReportsRoot
        _ = actionRoot
    }

    @Test
    @MainActor
    func appModelReflectsInjectedSnapshotReplacement() {
        let model = AppModel(data: makeSnapshot(totalTracks: 10, syncStatusText: "No sync yet", deltaCount: 2))

        model.applyData(makeSnapshot(totalTracks: 20, syncStatusText: "Synced now", deltaCount: 5))

        #expect(model.snapshot.totalTracks == 20)
        #expect(model.pipelineActivity.deltaCount == 5)
        #expect(model.data.syncStatusText == "Synced now")
    }

    @Test
    @MainActor
    func appModelMirrorsDryRunModeFromSnapshot() {
        let model = AppModel(data: makeSnapshot(safetyMode: .autoFix))

        #expect(!model.dryRun)

        model.applyData(makeSnapshot(safetyMode: .preview))

        #expect(model.dryRun)
    }

    @Test
    @MainActor
    func appModelReflectsSettingsSnapshotReplacement() {
        let initialSettings = DesignSettingsSnapshot(
            updateBehavior: .genreOnly,
            minimumConfidencePercent: 30,
            releaseYearRestoreThresholdYears: 5,
            testArtists: [],
            isPostWriteVerificationRequired: true
        )
        let updatedSettings = DesignSettingsSnapshot(
            updateBehavior: .yearOnly,
            minimumConfidencePercent: 80,
            releaseYearRestoreThresholdYears: 8,
            testArtists: ["Aphex Twin"],
            isPostWriteVerificationRequired: true
        )
        let model = AppModel(data: makeSnapshot(safetyMode: .preview, settings: initialSettings))

        model.applyData(makeSnapshot(safetyMode: .preview, settings: updatedSettings))

        #expect(model.data.settings.updateBehavior == .yearOnly)
        #expect(model.data.settings.minimumConfidencePercent == 80)
        #expect(model.data.settings.releaseYearRestoreThresholdYears == 8)
        #expect(model.data.settings.testArtists == ["Aphex Twin"])
    }

    private func makeSnapshot(totalTracks: Int, syncStatusText: String, deltaCount: Int) -> DesignDataSnapshot {
        makeSnapshot(
            totalTracks: totalTracks,
            syncStatusText: syncStatusText,
            deltaCount: deltaCount,
            safetyMode: .preview,
            settings: .preview
        )
    }

    private func makeSnapshot(
        totalTracks: Int = 10,
        syncStatusText: String = "No sync yet",
        deltaCount: Int = 2,
        safetyMode: PipelineSafetyMode,
        settings: DesignSettingsSnapshot = .preview
    ) -> DesignDataSnapshot {
        DesignDataSnapshot(
            health: makeHealth(totalTracks: totalTracks),
            pipelineActivity: makePipeline(deltaCount: deltaCount, safetyMode: safetyMode),
            pendingVerification: makePendingVerification(),
            coverage: [],
            issues: [],
            metrics: [],
            activity: [],
            artists: [],
            changes: [],
            dryRun: makeDryRunSummary(),
            changeLog: [],
            reportStats: ReportStats(processed: 0, genres: 0, years: 0),
            genreDistribution: [],
            updatesOverTime: [],
            yearDistribution: [],
            settings: settings,
            syncStatusText: syncStatusText,
            isPreviewBacked: false
        )
    }

    private func makePendingVerification() -> PendingVerificationSnapshot {
        PendingVerificationSnapshot(
            totalAlbums: 2,
            dueAlbums: 1,
            skippedByInterval: 0,
            problematicAlbums: 0,
            verifiedAlbums: 1
        )
    }

    private func makeHealth(totalTracks: Int) -> HealthSnapshot {
        HealthSnapshot(
            health: 0.8,
            genre: 0.9,
            year: 0.7,
            consistency: 0.6,
            totalTracks: totalTracks,
            totalAlbums: 2,
            missingGenre: 1,
            missingYear: 3,
            completeMetadata: 6,
            ready: 2,
            pendingVerification: 0,
            protectedFiles: 0,
            writeErrors: 0,
            recentlyAdded: 1,
            lastScan: "now",
            nextRun: "Manual scan only",
            source: "Music",
            library: "Music Library"
        )
    }

    private func makePipeline(deltaCount: Int, safetyMode: PipelineSafetyMode) -> PipelineActivitySnapshot {
        let pipeline = PipelineActivitySnapshot.previewDefault(
            deltaCount: deltaCount,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0
        )
        let descriptor = PipelineStageDescriptor(stage: .watch, detail: "No sync yet", status: .current)

        return PipelineActivitySnapshot(
            title: pipeline.title,
            subtitle: pipeline.subtitle,
            currentStage: pipeline.currentStage,
            safetyMode: safetyMode,
            automationState: .noSyncYet,
            deltaCount: pipeline.deltaCount,
            interventionCount: pipeline.interventionCount,
            protectedCount: pipeline.protectedCount,
            failedWriteCount: pipeline.failedWriteCount,
            isUndoReady: pipeline.isUndoReady,
            primaryAction: pipeline.primaryAction,
            secondaryAction: pipeline.secondaryAction,
            stageStatuses: [.watch: .current],
            stageDescriptors: [descriptor]
        )
    }

    private func makeDryRunSummary() -> DryRunSummary {
        DryRunSummary(
            changes: 0,
            tracks: 0,
            averageConfidence: 0,
            genre: 0,
            year: 0
        )
    }
}
