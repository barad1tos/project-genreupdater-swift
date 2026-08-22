import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow run facts")
@MainActor
struct WorkflowRunFactsTests {
    @Test("review scope remains tied to the run after settings change")
    func reviewScopeUsesCapturedRunFacts() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .smartFilter
        viewModel.smartFilterType = .missingGenres
        viewModel.previewOnly = true
        let runTrack = Track(
            id: "initial-track",
            name: "Initial",
            artist: "Initial Artist",
            album: "Initial Album"
        )
        var libraryTracks = [runTrack]
        var testArtists = [" Initial Artist "]

        viewModel.start(tracks: libraryTracks, testArtists: testArtists)
        try await waitForWorkflowToLeaveScanning(viewModel)
        viewModel.proposedChanges = [
            ProposedChange(
                track: runTrack,
                changeType: .genreUpdate,
                oldValue: nil,
                newValue: "Rock",
                confidence: 90,
                source: "Test"
            ),
        ]

        viewModel.mode = .fullLibrary
        viewModel.smartFilterType = .lowConfidence
        libraryTracks = [Track(id: "replacement", name: "Replacement", artist: "Other", album: "Other")]
        testArtists = ["Other"]
        let preview = UpdateResultPreviewAdapter.makeSnapshot(
            changes: viewModel.proposedChanges,
            scopeTitle: viewModel.runScopeTitle,
            hasCleaningAccess: true,
            primaryActionLabel: "Apply"
        )
        let previewAlbum = try #require(preview.albums.first)
        let previewTrack = try #require(previewAlbum.tracks.first)

        #expect(viewModel.runScopeTitle == "Test Artist: Initial Artist")
        #expect(preview.scope == "Test Artist: Initial Artist")
        #expect(previewAlbum.title == "Initial Artist — Initial Album")
        #expect(previewTrack.title == runTrack.name)
        #expect(previewTrack.artist == runTrack.artist)
        #expect(viewModel.capturedRunFacts?.tracks.map(\.id) == [runTrack.id])
        #expect(libraryTracks.map(\.id) == ["replacement"])
        #expect(testArtists == ["Other"])
    }

    @Test("done report and copy text use the run's original display facts")
    func doneReportUsesCapturedRunFacts() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .smartFilter
        viewModel.previewOnly = true
        let runTrack = Track(
            id: "run-track",
            name: "Run Title",
            artist: "Run Artist",
            album: "Run Album",
            genre: "Old Genre"
        )
        var libraryTracks = [runTrack]
        var testArtists = ["Run Artist"]

        viewModel.start(tracks: libraryTracks, testArtists: testArtists)
        try await waitForWorkflowToLeaveScanning(viewModel)

        var entry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: runTrack.id,
            artist: runTrack.artist,
            trackName: runTrack.name,
            albumName: runTrack.album
        )
        entry.oldGenre = "Old Genre"
        entry.newGenre = "New Genre"
        viewModel.result = BatchUpdateResult(
            entries: [entry],
            failedTrackIDs: [],
            errorDescriptions: []
        )
        viewModel.completedEntries = [entry]
        viewModel.trackStatuses = [runTrack.id: .done]
        viewModel.phase = .done

        libraryTracks = [Track(id: runTrack.id, name: "Reloaded Title", artist: "Other", album: "Other")]
        testArtists = ["Other"]
        let report = viewModel.makeRunReport(displayMode: .detailed)

        #expect(report.scopeTitle == "Test Artist: Run Artist")
        #expect(report.albumResults.first?.title == "Run Artist - Run Album")
        #expect(report.albumResults.first?.tracks.first?.title == "Run Title")
        #expect(report.plainTextSummary.contains("Scope: Test Artist: Run Artist"))
        #expect(report.plainTextSummary.contains("Run Artist - Run Album"))
        #expect(!report.plainTextSummary.contains("Reloaded Title"))
        #expect(libraryTracks.first?.name == "Reloaded Title")
        #expect(testArtists == ["Other"])

        viewModel.reset()

        #expect(viewModel.capturedRunFacts == nil)
    }
}
