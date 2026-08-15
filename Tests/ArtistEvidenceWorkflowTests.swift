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
