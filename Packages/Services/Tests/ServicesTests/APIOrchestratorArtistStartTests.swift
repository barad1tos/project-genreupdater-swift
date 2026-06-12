import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — artist start year parity")
struct APIOrchestratorArtistStartTests {
    @Test("Artist start year falls back to Apple Music when MusicBrainz has no activity period")
    func artistStartYearFallsBackToAppleMusic() async {
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(artistActivityPeriod: (nil, nil)),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(artistStartYear: 1998)
        )

        let year = await orchestrator.getArtistStartYear(normalizedArtist: "Test Artist")

        #expect(year == 1998)
    }
}
