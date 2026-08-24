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

    @Test("groups names with the same allow-list identity")
    func groupsLocalizedCaseVariants() {
        let projection = ArtistCatalogBuilder.makeProjection(tracks: [
            Track(id: "1", name: "First", artist: "Straße", album: "Album"),
            Track(id: "2", name: "Second", artist: "STRASSE", album: "Album"),
            Track(id: "3", name: "Third", artist: "Émilie Simon", album: "Album"),
            Track(id: "4", name: "Fourth", artist: "éMILIE SIMON", album: "Album"),
        ])

        #expect(projection.state == .available([
            ArtistCatalogEntry(name: "Émilie Simon", trackCount: 2),
            ArtistCatalogEntry(name: "Straße", trackCount: 2),
        ]))
    }

    @Test("assembles a large catalog without changing artist identities", .timeLimit(.minutes(1)))
    func assemblesLargeCatalog() {
        let tracks = (0 ..< 10000).map { index in
            Track(
                id: String(index),
                name: "Track \(index)",
                artist: String(format: "Artist %05d", index),
                album: "Album"
            )
        }

        let projection = ArtistCatalogBuilder.makeProjection(tracks: tracks)

        guard case let .available(entries) = projection.state else {
            Issue.record("Expected an available catalog")
            return
        }
        #expect(entries.count == 10000)
        #expect(entries.first == ArtistCatalogEntry(name: "Artist 00000", trackCount: 1))
        #expect(entries.last == ArtistCatalogEntry(name: "Artist 09999", trackCount: 1))
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
