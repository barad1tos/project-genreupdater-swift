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

    @Test("full-library write processes only resolved incremental candidates")
    func fullLibraryWriteProcessesOnlyResolvedIncrementalCandidates() async throws {
        let oldTrack = Track(id: "old-track", name: "Old", artist: "Clutch", album: "Old Album", year: 1999)
        let newTrack = Track(id: "new-track", name: "New", artist: "Clutch", album: "New Album", year: 1999)
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 90),
            resolveIncrementalTracks: { tracks in
                tracks.filter { $0.id == newTrack.id }
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [oldTrack, newTrack])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()

        #expect(writes.map(\.trackID) == [newTrack.id])
        #expect(viewModel.scopeTrackCount == 1)
    }

    @Test("empty incremental full-library scope completes without writes or timestamp")
    func emptyIncrementalFullLibraryScopeCompletesWithoutWritesOrTimestamp() async throws {
        let timestampUpdates = RunTimestampUpdateCounter()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 90),
            resolveIncrementalTracks: { _ in [] },
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
            Track(id: "old-track", name: "Old", artist: "Clutch", album: "Old Album", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "empty incremental scope should skip successfully, not error")
            return
        }
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
        #expect(await timestampUpdates.count() == 0)
        #expect(viewModel.result?.entries.isEmpty == true)
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
