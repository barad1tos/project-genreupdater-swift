import Core
import Services
import SwiftUI
import Testing
@testable import Genre_Updater

@Suite("Workflow run facts")
@MainActor
struct WorkflowRunFactsTests {
    @Test("review scope remains tied to the run after settings change")
    func keepsReviewRunFacts() async throws {
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
        let view = try UpdateWorkflowView(
            viewModel: viewModel,
            tracks: libraryTracks,
            testArtists: testArtists,
            reportDisplayMode: .detailed,
            credentialIssue: nil,
            libraryReadiness: makeReadyEvidence(),
            noticeMessage: .constant(nil)
        )
        let preview = view.makeReviewSnapshot(hasCleaningAccess: true)
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
    func keepsDoneRunFacts() async throws {
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
        let view = try UpdateWorkflowView(
            viewModel: viewModel,
            tracks: libraryTracks,
            testArtists: testArtists,
            reportDisplayMode: .detailed,
            credentialIssue: nil,
            libraryReadiness: makeReadyEvidence(),
            noticeMessage: .constant(nil)
        )
        let report = view.makeDoneReport()

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

        viewModel.start(tracks: libraryTracks, testArtists: testArtists)
        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(viewModel.capturedRunFacts?.tracks.map(\.name) == ["Reloaded Title"])
        #expect(viewModel.runScopeTitle == "Test Artist: Other")
    }

    @Test("empty effective runs report zero scanned tracks")
    func reportsEmptyEffectiveRun() async throws {
        let fixture = makeWorkflowFixture(resolveIncrementalTracks: { _, _ in [] })
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false
        let capturedTrack = Track(
            id: "captured",
            name: "Captured",
            artist: "Initial Artist",
            album: "Initial Album"
        )

        viewModel.start(tracks: [capturedTrack], testArtists: ["Initial Artist"])
        try await waitForWorkflowToLeaveScanning(viewModel)

        let liveTracks = [
            Track(id: "live-1", name: "Live One", artist: "Other", album: "Other"),
            Track(id: "live-2", name: "Live Two", artist: "Other", album: "Other"),
        ]
        let view = try UpdateWorkflowView(
            viewModel: viewModel,
            tracks: liveTracks,
            testArtists: ["Other"],
            reportDisplayMode: .detailed,
            credentialIssue: nil,
            libraryReadiness: makeReadyEvidence(),
            noticeMessage: .constant(nil)
        )
        let report = view.makeDoneReport()
        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: report)
        let metrics = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0.value) })

        #expect(viewModel.totalCount == 0)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(report.scannedTrackCount == 0)
        #expect(snapshot.subtitle == "0 tracks scanned")
        #expect(metrics["scanned-tracks"] == "0")
        #expect(report.plainTextSummary.contains("Tracks scanned: 0"))
        #expect(!report.plainTextSummary.contains("Tracks scanned: 1"))
        #expect(!report.plainTextSummary.contains("Tracks scanned: 2"))
    }

    @Test("empty release restore reports zero scanned tracks")
    func reportsEmptyRestoreRun() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5
        let capturedTrack = Track(
            id: "near-match",
            name: "Near Match",
            artist: "The Cure",
            album: "Wish",
            year: 1992,
            releaseYear: 1991
        )

        viewModel.start(tracks: [capturedTrack])
        await viewModel.processingTask?.value
        await Task.yield()

        let view = try UpdateWorkflowView(
            viewModel: viewModel,
            tracks: [Track(id: "live", name: "Live", artist: "Other", album: "Other")],
            testArtists: ["Other"],
            reportDisplayMode: .detailed,
            credentialIssue: nil,
            libraryReadiness: makeReadyEvidence(),
            noticeMessage: .constant(nil)
        )
        let report = view.makeDoneReport()
        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: report)

        #expect(viewModel.totalCount == 0)
        #expect(report.scannedTrackCount == 0)
        #expect(snapshot.subtitle == "0 tracks scanned")
        #expect(report.plainTextSummary.contains("Tracks scanned: 0"))
    }
}
