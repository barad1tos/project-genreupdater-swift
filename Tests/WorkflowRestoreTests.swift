import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow release-year restore")
@MainActor
struct WorkflowRestoreTests {
    @Test("Release-year restore marks tied consensus tracks as skipped")
    func releaseYearRestoreMarksTiedConsensusTracksAsSkipped() async {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "tie-1997",
                name: "First Tie",
                artist: "The Cure",
                album: "Wish",
                year: 2025,
                releaseYear: 1997
            ),
            Track(
                id: "tie-2001",
                name: "Second Tie",
                artist: "The Cure",
                album: "Wish",
                year: 2025,
                releaseYear: 2001
            ),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "tied release-year restore should complete without writes")
            return
        }
        #expect(viewModel.result?.entries.isEmpty == true)
        #expect(viewModel.result?.noOpEntries.isEmpty == true)
        #expect(viewModel.failedCount == 0)
        #expect(viewModel.trackStatuses["tie-1997"] == .skipped)
        #expect(viewModel.trackStatuses["tie-2001"] == .skipped)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }
}
