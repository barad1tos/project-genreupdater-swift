import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("Pending verification reports")
@MainActor
struct PendingReportWorkflowTests {
    @Test("ignores stale pending scope refresh after pending run")
    func ignoresStalePendingScopeRefreshAfterPendingRun() async throws {
        let pendingSnapshotDelay = PendingSnapshotDelay()
        let pendingRun = makeRandomAccessPendingViewModel(
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let viewModel = pendingRun.viewModel

        try await computeDelayedPendingScopePreview(
            viewModel: viewModel,
            tracks: randomAccessMemoriesMusicKitTracks(),
            pendingSnapshotDelay: pendingSnapshotDelay
        )

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())
        try await waitForWorkflowToLeaveScanning(viewModel)
        let finalSummary = try #require(viewModel.pendingVerificationReportSummary)
        expectPendingSummary(finalSummary, total: 1, due: 0, problematic: 0)

        await pendingSnapshotDelay.releaseFirstSnapshot()
        try await pendingSnapshotDelay.waitForDelayedPendingScopeRefreshCompletion()

        let summary = try #require(viewModel.pendingVerificationReportSummary)
        expectPendingSummary(summary, total: 1, due: 0, problematic: 0)
    }

    @Test("summarizes pending snapshot facts for update run reports")
    func summarizesPendingSnapshotFactsForUpdateRunReports() async throws {
        let dueEntry = randomAccessMemoriesPendingEntry()
        let problematicEntry = pureRockFuryPendingEntry()
        let skippedProblematicEntry = noisePendingEntry()
        let pendingSnapshotDelay = PendingSnapshotDelay()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [dueEntry, problematicEntry, skippedProblematicEntry],
            dueEntries: [dueEntry],
            problematicAlbums: [
                problematicPendingAlbum(entry: problematicEntry),
                problematicPendingAlbum(entry: skippedProblematicEntry, attempts: 4, daysSinceFirstAttempt: 21),
            ],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let viewModel = makeWorkflowFixture(pendingVerificationService: pendingVerification).viewModel
        viewModel.mode = .pendingVerification

        try await computeDelayedPendingScopePreview(
            viewModel: viewModel,
            tracks: [],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        await pendingSnapshotDelay.releaseFirstSnapshot()
        try await pendingSnapshotDelay.waitForDelayedPendingScopeRefreshCompletion()

        let summary = try #require(viewModel.pendingVerificationReportSummary)
        expectPendingSummary(summary, total: 3, due: 1, problematic: 2)
        #expect(summary.problematicDetails.map(\.album) == ["Pure Rock Fury", "Noise"])
        #expect(summary.problematicDetails.map(\.attemptCount) == [3, 4])
        #expect(summary.problematicDetails.allSatisfy { $0.nextVerification > $0.lastAttempt })

        viewModel.maintenancePreflightResult = staleDatabaseVerificationPreflight()
        viewModel.startPendingVerification(tracks: [])
        #expect(viewModel.maintenancePreflightResult == nil)
        try await waitForWorkflowToLeaveScanning(viewModel)

        let pendingOnlyReport = UpdateRunReport(
            result: viewModel.result,
            completedEntries: viewModel.completedEntries,
            trackStatuses: viewModel.trackStatuses,
            tracks: [],
            testArtists: [],
            operationalContext: UpdateRunOperationalContext(
                pendingVerification: viewModel.pendingVerificationReportSummary,
                databaseVerification: UpdateRunDatabaseVerificationSummary(
                    preflightResult: viewModel.maintenancePreflightResult
                )
            )
        )
        #expect(!pendingOnlyReport.plainTextSummary.contains("Database Verification"))

        viewModel.reset()
        #expect(viewModel.pendingVerificationReportSummary == nil)
        #expect(viewModel.maintenancePreflightResult == nil)

        viewModel.pendingVerificationReportSummary = summary
        viewModel.maintenancePreflightResult = staleDatabaseVerificationPreflight()
        viewModel.mode = .fullLibrary
        viewModel.start(tracks: [])
        #expect(viewModel.pendingVerificationReportSummary == nil)
        #expect(viewModel.maintenancePreflightResult == nil)
    }

    @Test("uses configured problematic album threshold for pending report summaries")
    func usesConfiguredProblematicAlbumThresholdForPendingReportSummaries() async throws {
        let dueEntry = randomAccessMemoriesPendingEntry()
        let retryingEntry = pureRockFuryPendingEntry()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [dueEntry, retryingEntry],
            dueEntries: [dueEntry],
            problematicAlbums: [
                problematicPendingAlbum(entry: retryingEntry, attempts: 4, daysSinceFirstAttempt: 21),
            ]
        )
        let viewModel = makeWorkflowFixture(
            pendingVerificationService: pendingVerification,
            configure: { options in
                options.problematicAlbumReportMinAttempts = { 5 }
            }
        ).viewModel
        viewModel.mode = .pendingVerification

        viewModel.computeScopePreview(tracks: [])

        for _ in 0 ..< 200 {
            if let summary = viewModel.pendingVerificationReportSummary {
                expectPendingSummary(summary, total: 2, due: 1, problematic: 0)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(Bool(false), "pending verification summary did not refresh before timeout")
    }
}
