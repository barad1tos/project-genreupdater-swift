import Foundation
import Testing
@testable import Services

@Suite("MusicLibraryReader catalog")
struct MusicLibraryReaderTests {
    @Test("MusicKit metadata maps to catalog presentation fields")
    func mapsCatalogMetadata() throws {
        let releaseDate = try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2023,
            month: 2,
            day: 10
        ).date)
        let dateAdded = Date(timeIntervalSince1970: 1_700_000_000)

        let track = try #require(MusicKitCatalogAdapter.makeTrack(from: MusicKitTrackMetadata(
            id: "music-kit-id",
            title: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            albumArtist: "In Flames",
            genres: ["Melodic Death Metal"],
            releaseDate: releaseDate,
            dateAdded: dateAdded
        )))

        #expect(track.id.displayValue == "music-kit-id")
        #expect(track.title == "Foregone Pt. 1")
        #expect(track.artist == "In Flames")
        #expect(track.album == "Foregone")
        #expect(track.albumArtist == "In Flames")
        #expect(track.genres == ["Melodic Death Metal"])
        #expect(track.dates.releaseYear == 2023)
        #expect(track.dates.dateAdded == dateAdded)
    }

    @Test("Blank catalog IDs are rejected")
    func rejectsBlankID() {
        #expect(CatalogTrackID(displayValue: " \n ") == nil)
        #expect(MusicKitCatalogAdapter.makeTrack(from: MusicKitTrackMetadata(
            id: "",
            title: "Battery",
            artist: "Metallica",
            album: "Master of Puppets",
            albumArtist: nil,
            genres: ["Metal"],
            releaseDate: nil,
            dateAdded: nil
        )) == nil)
    }

    @Test("Repeated catalog IDs produce one row")
    func deduplicatesCatalogIDs() {
        let snapshot = MusicKitCatalogAdapter.makeSnapshot(
            from: [
                Self.metadata(id: "MK-1", title: "Battery"),
                Self.metadata(id: "MK-1", title: "Battery (duplicate row)"),
            ]
        )

        #expect(snapshot.tracks.count == 1)
        #expect(snapshot.tracks.first?.title == "Battery")
    }

    @Test("Identical metadata with distinct catalog IDs remains distinct")
    func preservesDistinctIDs() {
        let snapshot = MusicKitCatalogAdapter.makeSnapshot(
            from: [
                Self.metadata(id: "MK-1", title: "Battery"),
                Self.metadata(id: "MK-2", title: "Battery"),
            ]
        )

        #expect(snapshot.tracks.map(\.id.displayValue) == ["MK-1", "MK-2"])
    }

    @Test("Test Artists never narrow physical catalog acquisition")
    func loadsEveryPhysicalCatalogRow() async throws {
        let source = CatalogSourceSpy(metadata: [
            Self.metadata(id: "MK-1", artist: "In Flames"),
            Self.metadata(id: "MK-2", artist: "Metallica"),
            Self.metadata(id: "MK-3", artist: "Björk"),
        ])
        let reader = MusicLibraryReader(source: source)

        let snapshot = try await reader.loadCatalog()

        #expect(snapshot.tracks.map(\.id.displayValue) == ["MK-1", "MK-2", "MK-3"])
        #expect(await source.loadCount() == 1)
    }

    @Test("Every MusicKit response page contributes to the physical catalog")
    func loadsEveryCatalogPage() async throws {
        let pages = [
            [Self.metadata(id: "MK-1")],
            [Self.metadata(id: "MK-2")],
            [Self.metadata(id: "MK-3")],
        ]

        let metadata = try await MusicKitPagination.collectMetadata(
            firstPage: 0,
            hasNextPage: { $0 < pages.index(before: pages.endIndex) },
            metadata: { pages[$0] },
            nextPage: { $0 + 1 }
        )

        #expect(metadata.map(\.id) == ["MK-1", "MK-2", "MK-3"])
    }

    @Test("A missing advertised MusicKit page fails closed")
    func rejectsMissingCatalogPage() async {
        await #expect(throws: MusicKitPaginationError.missingNextPage) {
            try await MusicKitPagination.collectMetadata(
                firstPage: 0,
                hasNextPage: { _ in true },
                metadata: { _ in [Self.metadata(id: "MK-1")] },
                nextPage: { _ in nil }
            )
        }
    }

    private static func metadata(
        id: String,
        title: String = "Song",
        artist: String = "Metallica",
        albumArtist: String? = nil
    ) -> MusicKitTrackMetadata {
        MusicKitTrackMetadata(
            id: id,
            title: title,
            artist: artist,
            album: "Album",
            albumArtist: albumArtist,
            genres: ["Metal"],
            releaseDate: nil,
            dateAdded: nil
        )
    }
}

private actor CatalogSourceSpy: MusicKitCatalogSource {
    private let metadata: [MusicKitTrackMetadata]
    private var loads = 0

    init(metadata: [MusicKitTrackMetadata]) {
        self.metadata = metadata
    }

    var isAuthorized: Bool {
        true
    }

    func requestAuthorization() async throws {
        // This catalog source spy is permanently authorized.
    }

    func loadTracks() async throws -> [MusicKitTrackMetadata] {
        loads += 1
        return metadata
    }

    func loadCount() -> Int {
        loads
    }
}
