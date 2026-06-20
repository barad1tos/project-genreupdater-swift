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

    @Test("Track filtering keeps only allowed effective artists")
    func filteringKeepsOnlyAllowedEffectiveArtists() {
        let tracks = [
            Track(id: "1", name: "Only for the Weak", artist: "In Flames", album: "Clayman"),
            Track(id: "2", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
        ]

        let filtered = ArtistAllowList.filter(tracks, allowedArtists: ["in flames"])

        #expect(filtered.map(\.id) == ["1"])
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
