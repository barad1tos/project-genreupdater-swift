import DesignUI
import Testing

@Suite("DesignUI public data contract")
struct DesignUIPublicAPITests {
    @Test
    @MainActor
    func snapshotCanBeConstructedOutsideDesignUIModule() {
        let data = makeSnapshot(totalTracks: 10, syncStatusText: "No sync yet", deltaCount: 2)
        let model = AppModel(data: data)
        let root = RootView(data: data)

        #expect(data.health.totalTracks == 10)
        #expect(data.pipelineActivity.deltaCount == 2)
        #expect(data.syncStatusText == "No sync yet")
        #expect(model.snapshot.totalTracks == 10)
        #expect(model.pipelineActivity.deltaCount == 2)
        _ = root
    }

    @Test
    @MainActor
    func appModelReflectsInjectedSnapshotReplacement() {
        let model = AppModel(data: makeSnapshot(totalTracks: 10, syncStatusText: "No sync yet", deltaCount: 2))

        model.data = makeSnapshot(totalTracks: 20, syncStatusText: "Synced now", deltaCount: 5)

        #expect(model.snapshot.totalTracks == 20)
        #expect(model.pipelineActivity.deltaCount == 5)
        #expect(model.data.syncStatusText == "Synced now")
    }

    private func makeSnapshot(totalTracks: Int, syncStatusText: String, deltaCount: Int) -> DesignDataSnapshot {
        DesignDataSnapshot(
            health: makeHealth(totalTracks: totalTracks),
            pipelineActivity: makePipeline(deltaCount: deltaCount),
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
            syncStatusText: syncStatusText,
            isPreviewBacked: false
        )
    }

    private func makeHealth(totalTracks: Int) -> HealthSnapshot {
        HealthSnapshot(
            health: 0.8,
            genre: 0.9,
            year: 0.7,
            consistency: 0.6,
            totalTracks: totalTracks,
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

    private func makePipeline(deltaCount: Int) -> PipelineActivitySnapshot {
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
            safetyMode: pipeline.safetyMode,
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
