import Foundation
import Testing
@testable import Services

@Suite("Artist catalog projection")
struct ArtistCatalogProjectionTests {
    @Test("groups effective artists case-insensitively and counts tracks")
    func groupsEffectiveArtists() {
        let tracks = [
            catalogTrack(id: "1", artist: "Guest", albumArtist: "In Flames"),
            catalogTrack(id: "2", artist: "IN FLAMES"),
            catalogTrack(id: "3", artist: "  "),
        ]

        let projection = ArtistCatalogBuilder.makeProjection(tracks: tracks)

        #expect(projection.state == .available([
            ArtistCatalogEntry(name: "In Flames", trackCount: 2),
        ]))
    }

    @Test("groups names with the same allow-list identity")
    func groupsLocalizedCaseVariants() {
        let projection = ArtistCatalogBuilder.makeProjection(tracks: [
            catalogTrack(id: "1", artist: "Straße"),
            catalogTrack(id: "2", artist: "STRASSE"),
            catalogTrack(id: "3", artist: "Émilie Simon"),
            catalogTrack(id: "4", artist: "éMILIE SIMON"),
        ])

        #expect(projection.state == .available([
            ArtistCatalogEntry(name: "Émilie Simon", trackCount: 2),
            ArtistCatalogEntry(name: "Straße", trackCount: 2),
        ]))
    }

    @Test("assembles a large catalog without changing artist identities", .timeLimit(.minutes(1)))
    func assemblesLargeCatalog() {
        let tracks = (0 ..< 10000).map { index in
            catalogTrack(id: String(index), artist: String(format: "Artist %05d", index))
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
                catalogTrack(id: "new", artist: "Björk"),
            ]),
            inputGeneration: newerGeneration
        )
        let stored = await store.replaceArtistCatalog(
            ArtistCatalogBuilder.makeProjection(tracks: [
                catalogTrack(id: "old", artist: "Cher"),
            ]),
            inputGeneration: olderGeneration
        )

        #expect(stored.state == .available([
            ArtistCatalogEntry(name: "Björk", trackCount: 1),
        ]))
    }
}

private func catalogTrack(id: String, artist: String, albumArtist: String? = nil) -> CatalogTrack {
    guard let catalogID = CatalogTrackID(displayValue: id) else {
        fatalError("Catalog fixture IDs must be non-empty")
    }
    return CatalogTrack(
        id: catalogID,
        title: "Track",
        artist: artist,
        album: "Album",
        albumArtist: albumArtist,
        genres: [],
        releaseYear: nil,
        dateAdded: nil
    )
}
