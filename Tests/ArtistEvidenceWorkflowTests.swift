import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow artist evidence")
@MainActor
struct ArtistEvidenceWorkflowTests {
    @Test("full library preview groups explicit feature credits")
    func featureCreditPreview() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = true
        viewModel.updateYear = false

        viewModel.start(tracks: featureCreditGenreTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        let genreChange = try #require(viewModel.proposedChanges.first { $0.changeType == .genreUpdate })
        #expect(genreChange.track.id == "target")
        #expect(genreChange.newValue == "Post-Punk")
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library batch groups explicit feature credits")
    func featureCreditBatch() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false

        viewModel.start(tracks: featureCreditGenreTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .done = viewModel.phase else {
            Issue.record("Expected the feature-credit batch to complete")
            return
        }
        #expect(await fixture.scriptClient.updatedProperties() == [
            TrackPropertyUpdate(trackID: "target", property: "genre", value: "Post-Punk"),
        ])
    }

    @Test("preview restores album artist before grouping feature credits")
    func enrichedAlbumArtistPreview() async throws {
        let fixture = enrichedAlbumArtistFixture()
        let viewModel = fixture.viewModel
        configureGenreRun(viewModel, previewOnly: true)

        viewModel.start(tracks: featureCreditGenreTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(viewModel.proposedChanges.isEmpty)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("batch restores album artist before grouping feature credits")
    func enrichedAlbumArtistBatch() async throws {
        let fixture = enrichedAlbumArtistFixture()
        let viewModel = fixture.viewModel
        configureGenreRun(viewModel, previewOnly: false)

        viewModel.start(tracks: featureCreditGenreTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .done = viewModel.phase else {
            Issue.record("Expected the enriched album-artist batch to complete")
            return
        }
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.entries.isEmpty == true)
        #expect(viewModel.result?.noOpEntries.isEmpty == true)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("batch keeps unmapped tracks as read-only artist evidence")
    func unmappedArtistEvidenceBatch() async throws {
        let rawTracks = featureCreditGenreTracks()
        var enrichedTarget = rawTracks[1]
        enrichedTarget.albumArtist = "Artist"
        enrichedTarget.appleScriptID = "as-target"
        enrichedTarget.trackStatus = TrackKind.purchased.rawValue
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == "target" }
            },
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: [enrichedTarget],
                appleScriptIDsByMusicKitID: ["target": "as-target"]
            )
        )
        let viewModel = fixture.viewModel
        configureGenreRun(viewModel, previewOnly: false)

        viewModel.start(tracks: rawTracks)

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .done = viewModel.phase else {
            Issue.record("Expected the partial-mapping batch to complete")
            return
        }
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.errorDescriptions.isEmpty == true)
        #expect(await fixture.scriptClient.updatedProperties() == [
            TrackPropertyUpdate(trackID: "as-target", property: "genre", value: "Post-Punk"),
        ])
    }

    private func configureGenreRun(_ viewModel: WorkflowViewModel, previewOnly: Bool) {
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = previewOnly
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false
    }

    private func enrichedAlbumArtistFixture() -> WorkflowFixture {
        let rawTracks = featureCreditGenreTracks()
        let enrichedTracks = rawTracks.map { track in
            var enrichedTrack = track
            enrichedTrack.albumArtist = track.artist
            enrichedTrack.appleScriptID = "as-\(track.id)"
            return enrichedTrack
        }
        return makeWorkflowFixture(
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: enrichedTracks,
                appleScriptIDsByMusicKitID: Dictionary(
                    uniqueKeysWithValues: enrichedTracks.map { ($0.id, "as-\($0.id)") }
                )
            )
        )
    }

    private func featureCreditGenreTracks() -> [Track] {
        [
            Track(
                id: "source",
                name: "Source Song",
                artist: "Artist",
                album: "Earlier Album",
                genre: "Post-Punk",
                dateAdded: Date(timeIntervalSince1970: 100)
            ),
            Track(
                id: "target",
                name: "Target Song",
                artist: "Artist feat. Guest",
                album: "Later Album",
                genre: nil,
                dateAdded: Date(timeIntervalSince1970: 200)
            ),
        ]
    }
}
