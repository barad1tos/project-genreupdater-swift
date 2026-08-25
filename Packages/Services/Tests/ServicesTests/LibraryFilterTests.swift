import Foundation
import Testing
@testable import Services

@Suite("Music catalog Test Artists filtering")
struct LibraryFilterTests {
    @Test("Empty Test Artists returns every catalog row")
    func keepsAllUnscoped() {
        let snapshot = MusicKitCatalogAdapter.makeSnapshot(
            from: library,
            testArtists: [],
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.tracks.count == library.count)
    }

    @Test("Filtering is case-insensitive and uses the album-artist hint")
    func usesAlbumArtistHint() {
        let snapshot = MusicKitCatalogAdapter.makeSnapshot(
            from: library,
            testArtists: ["beatles"],
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.tracks.map(\.id.displayValue) == ["1"])
    }

    @Test("Multiple Test Artists retain matching rows")
    func retainsAllowedArtists() {
        let snapshot = MusicKitCatalogAdapter.makeSnapshot(
            from: library,
            testArtists: ["Beatles", "Queen"],
            observedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.tracks.map(\.id.displayValue) == ["1", "2"])
    }

    private let library = [
        metadata(id: "1", artist: "John Lennon", albumArtist: "Beatles"),
        metadata(id: "2", artist: "Queen"),
        metadata(id: "3", artist: "Pink Floyd"),
    ]
}

private func metadata(
    id: String,
    artist: String,
    albumArtist: String? = nil
) -> MusicKitTrackMetadata {
    MusicKitTrackMetadata(
        id: id,
        title: "Song",
        artist: artist,
        album: "Album",
        albumArtist: albumArtist,
        genres: [],
        releaseDate: nil,
        dateAdded: nil
    )
}
