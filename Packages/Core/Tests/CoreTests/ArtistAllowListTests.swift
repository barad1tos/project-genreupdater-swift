import Testing
@testable import Core

@Suite("Artist allow-list")
struct ArtistAllowListTests {
    @Test("Normalization trims blanks and removes case-insensitive duplicates")
    func normalizationTrimsBlanksAndDeduplicatesArtists() {
        let artists = ArtistAllowList.normalized([" In Flames ", "", "in flames", "Dark Tranquillity"])

        #expect(artists == ["In Flames", "Dark Tranquillity"])
    }

    @Test("Empty allow-list allows every artist")
    func emptyAllowListAllowsEveryArtist() {
        #expect(ArtistAllowList.contains("Beatles", in: []))
        #expect(ArtistAllowList.contains("Beatles", in: ["  "]))
    }

    @Test("Track filtering keeps only allowed artists")
    func filteringKeepsOnlyAllowedArtists() {
        let tracks = [
            Track(id: "1", name: "Only for the Weak", artist: "In Flames", album: "Clayman"),
            Track(id: "2", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
        ]

        let filtered = ArtistAllowList.filter(tracks, allowedArtists: ["in flames"])

        #expect(filtered.map(\.id) == ["1"])
    }

    @Test("Track scope matches either primary artist or album artist")
    func trackScopeMatchesEitherArtistField() {
        let primaryMatch = Track(
            id: "primary",
            name: "Song",
            artist: "Target",
            album: "Album",
            albumArtist: "Other"
        )
        let albumMatch = Track(
            id: "album",
            name: "Song",
            artist: "Other",
            album: "Album",
            albumArtist: "Target"
        )

        #expect(ArtistAllowList.filter(
            [primaryMatch, albumMatch],
            allowedArtists: ["target"]
        ).map(\.id) == ["primary", "album"])
    }

    @Test("Track filtering supports Cyrillic artist names")
    func filteringSupportsCyrillicArtistNames() {
        let tracks = [
            Track(id: "1", name: "Пісня", artist: "паліндром", album: "Придумано в черзі"),
            Track(id: "2", name: "Only for the Weak", artist: "In Flames", album: "Clayman"),
        ]

        let filtered = ArtistAllowList.filter(tracks, allowedArtists: ["Паліндром"])

        #expect(filtered.map(\.id) == ["1"])
    }
}
