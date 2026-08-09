import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — artist region memoization")
struct ArtistRegionAPITests {
    @Test("The region comes from MusicBrainz and memoizes for a year")
    func regionMemoizes() async {
        let cache = MockCacheService()
        let first = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistRegion: "Ukraine"),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        #expect(await first.getArtistRegion(normalizedArtist: "okean elzy") == "Ukraine")

        // A second orchestrator with a DIFFERENT answer proves the hit
        // comes from the shared cache, not the client.
        let second = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistRegion: "Poland"),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        #expect(await second.getArtistRegion(normalizedArtist: "okean elzy") == "Ukraine")
    }

    @Test("A confirmed miss is a negative sentinel, not a retry storm")
    func missMemoizesNegatively() async {
        let cache = MockCacheService()
        let first = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistRegion: nil),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        #expect(await first.getArtistRegion(normalizedArtist: "unknown artist") == nil)

        let second = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistRegion: "Poland"),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        #expect(await second.getArtistRegion(normalizedArtist: "unknown artist") == nil)
    }

    @Test("No cache still answers from the client")
    func worksWithoutCache() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistRegion: "Iceland"),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )

        #expect(await orchestrator.getArtistRegion(normalizedArtist: "bjork") == "Iceland")
    }
}
