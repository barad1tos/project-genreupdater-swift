import Core
import Testing
@testable import Services

@Suite("Artist catalog projection")
struct ArtistCatalogProjectionTests {
    @Test("groups effective artists case-insensitively and counts tracks")
    func groupsEffectiveArtists() {
        let tracks = [
            Track(id: "1", name: "First", artist: "Guest", album: "Album", albumArtist: "In Flames"),
            Track(id: "2", name: "Second", artist: "IN FLAMES", album: "Album"),
            Track(id: "3", name: "Blank", artist: "  ", album: "Album"),
        ]

        let projection = ArtistCatalogBuilder.makeProjection(tracks: tracks)

        #expect(projection.state == .available([
            ArtistCatalogEntry(name: "In Flames", trackCount: 2),
        ]))
    }

    @Test("projection store rejects an older catalog generation")
    func rejectsOlderGeneration() async {
        let store = ProjectionStore()
        let olderGeneration = await store.claimArtistCatalogGeneration()
        let newerGeneration = await store.claimArtistCatalogGeneration()

        _ = await store.replaceArtistCatalog(
            ArtistCatalogBuilder.makeProjection(tracks: [
                Track(id: "new", name: "Track", artist: "Björk", album: "Album"),
            ]),
            inputGeneration: newerGeneration
        )
        let stored = await store.replaceArtistCatalog(
            ArtistCatalogBuilder.makeProjection(tracks: [
                Track(id: "old", name: "Track", artist: "Cher", album: "Album"),
            ]),
            inputGeneration: olderGeneration
        )

        #expect(stored.state == .available([
            ArtistCatalogEntry(name: "Björk", trackCount: 1),
        ]))
    }
}
