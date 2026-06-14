import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("Browse selection update scope")
@MainActor
struct BrowseSelectionTests {
    @Test("selected artist expands to all artist tracks")
    func selectedArtistExpandsToAllArtistTracks() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = [BrowseSelectionItem.artistID("Alpha")]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2"])
    }

    @Test("selected canonical artist expands normalized variants")
    func selectedCanonicalArtistExpandsNormalizedVariants() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = [
            Track(id: "alpha-1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "alpha-2", name: "Two", artist: "The Alpha", album: "Second"),
        ]
        viewModel.selectedItems = [BrowseSelectionItem.artistID("Alpha")]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2"])
    }

    @Test("selected album expands to album tracks")
    func selectedAlbumExpandsToAlbumTracks() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = [BrowseSelectionItem.albumID(AlbumSummary.makeID(artist: "Alpha", name: "First"))]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2"])
    }

    @Test("selected album supports pipe characters in artist names")
    func selectedAlbumSupportsPipeCharactersInArtistNames() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = [
            Track(id: "other-1", name: "Other", artist: "A", album: "B|Live"),
            Track(id: "pipe-1", name: "Pipe One", artist: "A|B", album: "Live"),
        ]
        let intendedAlbumID = AlbumSummary.makeID(artist: "A|B", name: "Live")
        let collidingAlbumID = AlbumSummary.makeID(artist: "A", name: "B|Live")
        viewModel.selectedItems = [BrowseSelectionItem.albumID(intendedAlbumID)]

        #expect(intendedAlbumID != collidingAlbumID)
        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["pipe-1"])
    }

    @Test("selected track IDs are preserved as update scope")
    func selectedTrackIDsArePreservedAsUpdateScope() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = [BrowseSelectionItem.trackID("beta-1")]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["beta-1"])
    }

    @Test("track ID collision with artist name does not overselect artist")
    func trackIDCollisionWithArtistNameDoesNotOverselectArtist() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = [
            Track(id: "Alpha", name: "Track ID Collision", artist: "Gamma", album: "Third"),
            Track(id: "alpha-1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "alpha-2", name: "Two", artist: "Alpha", album: "First"),
        ]
        viewModel.selectedItems = [BrowseSelectionItem.trackID("Alpha")]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["Alpha"])
    }

    @Test("mixed selection removes duplicates and keeps library order")
    func mixedSelectionRemovesDuplicatesAndKeepsLibraryOrder() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = [
            BrowseSelectionItem.artistID("Alpha"),
            BrowseSelectionItem.albumID(AlbumSummary.makeID(artist: "Alpha", name: "First")),
            BrowseSelectionItem.trackID("alpha-1"),
            BrowseSelectionItem.trackID("beta-1"),
        ]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2", "beta-1"])
    }

    @Test("browse update request parses typed action and selected items")
    func browseUpdateRequestParsesTypedActionAndSelectedItems() throws {
        let notification = Notification(
            name: .browseAction,
            object: nil,
            userInfo: [
                BrowseUpdateAction.actionUserInfoKey: BrowseUpdateAction.years.rawValue,
                BrowseUpdateAction.selectedItemsUserInfoKey: Set([BrowseSelectionItem.trackID("alpha-1")]),
            ]
        )

        let request = try #require(BrowseUpdateRequest(notification: notification))

        #expect(request.action == .years)
        #expect(request.selectedItems == [BrowseSelectionItem.trackID("alpha-1")])
    }

    private func makeTracks() -> [Track] {
        [
            Track(id: "alpha-1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "alpha-2", name: "Two", artist: "Alpha", album: "First"),
            Track(id: "beta-1", name: "Three", artist: "Beta", album: "Second"),
        ]
    }
}
