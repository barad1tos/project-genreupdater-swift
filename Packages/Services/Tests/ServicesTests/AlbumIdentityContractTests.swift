import Testing
@testable import Core
@testable import Services

extension AlbumIdentityFlowTests {
    @Test("Legal artist names remain intact through API lookup and cache write")
    func keepsLegalArtist() async throws {
        let cache = MockCacheService()
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(
            probe: apiProbe,
            yearResult: YearResult(
                year: 2009,
                isDefinitive: true,
                confidence: 100,
                yearScores: [2009: 100]
            )
        )
        let coordinator = makeCoordinator(apiService: apiService, cache: cache)
        let track = Track(
            id: "florence-lungs",
            name: "Dog Days Are Over",
            artist: "Florence and the Machine",
            album: "Lungs",
            year: 2010
        )

        _ = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let requests = await apiProbe.albumRequests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.artist == "Florence and the Machine" })
        #expect(await cache.getAlbumYear(artist: "Florence and the Machine", album: "Lungs")?.year == 2009)
        #expect(await cache.getAlbumYear(artist: "Florence", album: "Lungs") == nil)
    }
}
