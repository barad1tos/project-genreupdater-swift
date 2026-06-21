import Core
import Testing
@testable import Genre_Updater

@MainActor
@Suite("Workflow run tracker policy")
struct WorkflowRunTrackerTests {
    @Test("full-library write updates incremental run timestamp after successful batch")
    func fullLibraryWriteUpdatesIncrementalRunTimestampAfterSuccessfulBatch() async throws {
        let timestampUpdates = RunTimestampUpdateCounter()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 90),
            updateIncrementalRunTimestamp: {
                await timestampUpdates.record()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "missing-year", name: "Track", artist: "Clutch", album: "Pure Rock Fury", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await timestampUpdates.count() == 1)
    }

    @Test("full-library dry run does not update incremental run timestamp")
    func fullLibraryDryRunDoesNotUpdateIncrementalRunTimestamp() async throws {
        let timestampUpdates = RunTimestampUpdateCounter()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 90),
            updateIncrementalRunTimestamp: {
                await timestampUpdates.record()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "missing-year", name: "Track", artist: "Clutch", album: "Pure Rock Fury", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await timestampUpdates.count() == 0)
    }

    @Test("failed full-library batch does not update incremental run timestamp")
    func failedFullLibraryBatchDoesNotUpdateIncrementalRunTimestamp() async throws {
        let timestampUpdates = RunTimestampUpdateCounter()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 90),
            failingWriteTrackIDs: ["missing-year"],
            updateIncrementalRunTimestamp: {
                await timestampUpdates.record()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "missing-year", name: "Track", artist: "Clutch", album: "Pure Rock Fury", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await timestampUpdates.count() == 0)
    }
}

private actor RunTimestampUpdateCounter {
    private var updates = 0

    func record() {
        updates += 1
    }

    func count() -> Int {
        updates
    }
}
