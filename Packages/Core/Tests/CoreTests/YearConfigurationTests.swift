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
}
