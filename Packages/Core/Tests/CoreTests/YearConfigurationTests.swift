import Foundation
import Testing
@testable import Core

@Suite("Year configuration persistence")
struct YearConfigurationTests {
    @Test("Persisted dominance threshold overrides the current default")
    func explicitDominanceThresholdRoundTrips() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.dominantYearMinConfidence = 0.8

        let data = try JSONEncoder().encode(configuration)
        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: data
        )

        #expect(decoded.yearRetrieval.logic.dominantYearMinConfidence == 0.8)
    }

    @Test("Persisted dominance threshold controls local year decisions")
    func persistedThresholdApplies() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.dominantYearMinConfidence = 0.8
        let data = try JSONEncoder().encode(configuration)
        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: data
        )
        let tracks = [
            Track(
                id: "ram-1",
                name: "Give Life Back to Music",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: 2013
            ),
            Track(
                id: "ram-2",
                name: "The Game of Love",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: 2013
            ),
            Track(
                id: "ram-3",
                name: "Giorgio by Moroder",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: 2013
            ),
            Track(id: "ram-4", name: "Within", artist: "Daft Punk", album: "Random Access Memories", year: 2014),
            Track(id: "ram-5", name: "Instant Crush", artist: "Daft Punk", album: "Random Access Memories", year: 2014),
        ]

        let result = YearValidator(config: decoded.yearRetrieval.logic)
            .getDominantYear(tracks: tracks)

        #expect(result == nil)
    }
}
