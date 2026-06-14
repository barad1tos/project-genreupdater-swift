import Core
import Testing
@testable import Genre_Updater

@Suite("Browse selection update scope")
@MainActor
struct BrowseSelectionTests {
    @Test("selected artist expands to all artist tracks")
    func selectedArtistExpandsToAllArtistTracks() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = ["Alpha"]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2"])
    }

    @Test("selected album expands to album tracks")
    func selectedAlbumExpandsToAlbumTracks() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = ["Alpha|First"]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2"])
    }

    @Test("selected track IDs are preserved as update scope")
    func selectedTrackIDsArePreservedAsUpdateScope() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = ["beta-1"]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["beta-1"])
    }

    @Test("mixed selection removes duplicates and keeps library order")
    func mixedSelectionRemovesDuplicatesAndKeepsLibraryOrder() {
        let viewModel = BrowseViewModel()
        viewModel.tracks = makeTracks()
        viewModel.selectedItems = ["Alpha", "Alpha|First", "alpha-1", "beta-1"]

        #expect(viewModel.selectedTracksForUpdate().map(\.id) == ["alpha-1", "alpha-2", "beta-1"])
    }

    private func makeTracks() -> [Track] {
        [
            Track(id: "alpha-1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "alpha-2", name: "Two", artist: "Alpha", album: "First"),
            Track(id: "beta-1", name: "Three", artist: "Beta", album: "Second"),
        ]
    }
}
