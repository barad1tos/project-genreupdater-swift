import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow pending cancellation")
@MainActor
struct WorkflowPendingCancelTests {
    @Test("successful preflight entries stay visible after live batch cancellation")
    func successfulPreflightEntriesStayVisibleAfterLiveBatchCancellation() async throws {
        let run = makeRandomAccessLiveBatchRun(cancellingWriteTrackIDs: ["as-batch-year"])
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToReturnToConfigure(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.entries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.errorDescriptions.isEmpty == true)
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.trackStatuses["batch-year"] == nil)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(await run.timestampUpdates.count() == 0)
    }

    @Test("successful preflight entries stay visible after user batch cancellation")
    func successfulPreflightEntriesStayVisibleAfterUserBatchCancellation() async throws {
        let liveBatchHold = LiveBatchHold()
        let firstBatchTrack = batchYearTrack(id: "batch-year-1")
        let secondBatchTrack = batchYearTrack(id: "batch-year-2")
        let apiService = DashboardStateAPIService(
            year: 2013,
            confidence: 100,
            beforeAlbumYearLookup: {
                await liveBatchHold.holdOnce()
            }
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: WorkflowPendingVerificationService(entries: []),
            apiService: apiService,
            additionalEnrichedTracks: [firstBatchTrack, secondBatchTrack],
            additionalAppleScriptIDsByMusicKitID: [
                "batch-year-1": "as-batch-year-1",
                "batch-year-2": "as-batch-year-2",
            ]
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.forceYearLookup = true
        let preflightOutcome = PendingEntryOutcome(
            completed: [
                ChangeLogEntry(changeType: .yearUpdate, trackID: "ram-1", artist: "Daft Punk"),
                ChangeLogEntry(changeType: .yearUpdate, trackID: "ram-2", artist: "Daft Punk"),
            ],
            successfulTrackIDs: ["ram-1", "ram-2"],
            processedCount: 2
        )

        viewModel.startBatchProcessing(
            tracks: [firstBatchTrack, secondBatchTrack],
            preflightOutcome: preflightOutcome
        )
        await liveBatchHold.waitUntilHeld()
        viewModel.cancel()
        await liveBatchHold.release()

        try await waitForWorkflowToReturnToConfigure(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()

        #expect(writes.map(\.trackID) == ["as-batch-year-1"])
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.entries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.errorDescriptions.isEmpty == true)
        #expect(viewModel.processedCount == 3)
        #expect(viewModel.totalCount == 4)
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.trackStatuses["batch-year-1"] == nil)
        #expect(viewModel.trackStatuses["batch-year-2"] == nil)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
    }

    @Test("successful pending entries stay visible after preflight cancellation")
    func successfulPendingEntriesStayVisibleAfterPreflightCancellation() async throws {
        let pendingEntries = [
            randomAccessMemoriesPendingEntry(),
            pureRockFuryPendingEntry(),
        ]
        let pendingVerification = WorkflowPendingVerificationService(
            entries: pendingEntries,
            dueEntries: pendingEntries
        )
        let run = makeRandomAccessLiveBatchRun(
            pendingVerificationService: pendingVerification,
            cancellingWriteTrackIDs: ["as-batch-year"]
        )
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToReturnToConfigure(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.entries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.errorDescriptions.isEmpty == true)
        #expect(viewModel.processedCount == 2)
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.trackStatuses["batch-year"] == nil)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 0)
    }

    @Test("completed pending entries stay visible when timestamp update is cancelled")
    func completedPendingEntriesStayVisibleWhenTimestampUpdateIsCancelled() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()],
            timestampUpdateFailure: CancellationError()
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToReturnToConfigure(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.entries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("completed pending entries stay visible when timestamp update fails")
    func completedPendingEntriesStayVisibleWhenTimestampUpdateFails() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()],
            timestampUpdateFailure: PendingTimestampUpdateError.failed
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.entries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        if case let .error(message) = viewModel.phase {
            #expect(message == PendingTimestampUpdateError.failed.localizedDescription)
        } else {
            Issue.record("Expected timestamp update failure to keep workflow in error phase")
        }
    }

    @Test("empty preflight cancellation clears stale batch result")
    func emptyPreflightCancellationClearsStaleBatchResult() async throws {
        let liveBatchHold = LiveBatchHold()
        let firstBatchTrack = batchYearTrack(id: "batch-year-1")
        let secondBatchTrack = batchYearTrack(id: "batch-year-2")
        let staleEntry = ChangeLogEntry(changeType: .yearUpdate, trackID: "stale", artist: "Archive")
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: WorkflowPendingVerificationService(entries: []),
            apiService: DashboardStateAPIService(
                year: 2013,
                confidence: 100,
                beforeAlbumYearLookup: {
                    await liveBatchHold.holdOnce()
                }
            ),
            additionalEnrichedTracks: [firstBatchTrack, secondBatchTrack],
            additionalAppleScriptIDsByMusicKitID: [
                "batch-year-1": "as-batch-year-1",
                "batch-year-2": "as-batch-year-2",
            ]
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.forceYearLookup = true
        viewModel.completedEntries = [staleEntry]
        viewModel.result = BatchUpdateResult(entries: [staleEntry], failedTrackIDs: [], errorDescriptions: [])

        viewModel.startBatchProcessing(tracks: [firstBatchTrack, secondBatchTrack])
        await liveBatchHold.waitUntilHeld()
        viewModel.cancel()
        await liveBatchHold.release()

        try await waitForWorkflowToReturnToConfigure(viewModel)

        #expect(viewModel.completedEntries.isEmpty)
        #expect(viewModel.result == nil)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
    }

    @Test("cancelling pending preflight does not start live batch")
    func cancellingPendingPreflightDoesNotStartLiveBatch() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            cancellingWriteTrackIDs: ["as-ram-1"],
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToReturnToConfigure(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.isEmpty)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }
}

private enum PendingTimestampUpdateError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Timestamp update failed"
    }
}
