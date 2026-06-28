import DesignUI
import Testing

@Suite("DesignUI public data contract")
struct DesignUIPublicAPITests {
    @Test
    func snapshotCanBeConstructedOutsideDesignUIModule() {
        let health = HealthSnapshot(
            health: 0.8,
            genre: 0.9,
            year: 0.7,
            consistency: 0.6,
            totalTracks: 10,
            missingGenre: 1,
            missingYear: 3,
            completeMetadata: 6,
            ready: 2,
            pendingVerification: 0,
            protectedFiles: 0,
            writeErrors: 0,
            recentlyAdded: 1,
            lastScan: "now",
            nextRun: "manual",
            source: "Music",
            library: "Music Library"
        )
        let pipeline = PipelineActivitySnapshot.previewDefault(
            deltaCount: 2,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0
        )
        let data = DesignDataSnapshot(
            health: health,
            pipelineActivity: pipeline,
            coverage: [],
            issues: [],
            metrics: [],
            activity: [],
            artists: [],
            changes: [],
            dryRun: DryRunSummary(
                changes: 0,
                tracks: 0,
                averageConfidence: 0,
                genre: 0,
                year: 0
            ),
            changeLog: [],
            reportStats: ReportStats(processed: 0, genres: 0, years: 0),
            genreDistribution: [],
            updatesOverTime: [],
            yearDistribution: [],
            syncStatusText: "No sync yet",
            isPreviewBacked: false
        )

        #expect(data.health.totalTracks == 10)
        #expect(data.pipelineActivity.deltaCount == 2)
        #expect(data.syncStatusText == "No sync yet")
    }
}
