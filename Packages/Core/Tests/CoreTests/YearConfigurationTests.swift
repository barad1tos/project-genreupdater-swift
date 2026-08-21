import Foundation
import Testing
@testable import Core

@Suite("Year configuration persistence")
struct YearConfigurationTests {
    @Test("Pre-Discogs-search settings use the Python acquisition defaults")
    func preDiscogsSearchSettingsUseDefaults() throws {
        let data = Data(
            #"""
            {
              "yearRetrieval": {
                "preferredAPI": "discogs"
              }
            }
            """#.utf8
        )

        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: data
        )

        #expect(decoded.yearRetrieval.discogsSearch.resultLimit == 25)
        #expect(decoded.yearRetrieval.discogsSearch.detailLookupLimit == 10)
    }

    @Test("Persisted Discogs search settings preserve explicit and missing values")
    func discogsSearchSettingsRoundTrip() throws {
        let data = Data(
            #"""
            {
              "yearRetrieval": {
                "discogsSearch": {
                  "resultLimit": 17
                }
              }
            }
            """#.utf8
        )

        var decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: data
        )
        #expect(decoded.yearRetrieval.discogsSearch.resultLimit == 17)
        #expect(decoded.yearRetrieval.discogsSearch.detailLookupLimit == 10)

        decoded.yearRetrieval.discogsSearch.detailLookupLimit = 3
        let roundTrip = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTrip.yearRetrieval.discogsSearch.resultLimit == 17)
        #expect(roundTrip.yearRetrieval.discogsSearch.detailLookupLimit == 3)
    }

    @Test("Pre-G2 year logic keeps its values and defaults local-source policy")
    func preG2LogicDefaultsLocalSourcePolicy() throws {
        let data = Data(
            #"""
            {
              "yearRetrieval": {
                "logic": {
                  "minValidYear": 1900,
                  "absurdYearThreshold": 1970,
                  "suspicionThresholdYears": 10,
                  "definitiveScoreThreshold": 50,
                  "definitiveScoreDiff": 15,
                  "minConfidenceForNewYear": 42,
                  "majorMarketCodes": ["us", "gb"],
                  "dominantYearMinConfidence": 0.8
                }
              }
            }
            """#.utf8
        )

        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: data
        )

        #expect(decoded.yearRetrieval.logic.minConfidenceForNewYear == 42)
        #expect(decoded.yearRetrieval.logic.majorMarketCodes == ["us", "gb"])
        #expect(decoded.yearRetrieval.logic.dominantYearMinConfidence == 0.8)
        #expect(decoded.yearRetrieval.logic.cacheTrustThreshold == 90)
        #expect(decoded.yearRetrieval.logic.consensusYearConfidence == 80)
    }

    @Test("Persisted local-source policy overrides both defaults")
    func explicitLocalSourcePolicyRoundTrips() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.cacheTrustThreshold = 94
        configuration.yearRetrieval.logic.consensusYearConfidence = 73

        let data = try JSONEncoder().encode(configuration)
        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: data
        )

        #expect(decoded.yearRetrieval.logic.cacheTrustThreshold == 94)
        #expect(decoded.yearRetrieval.logic.consensusYearConfidence == 73)
    }

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

    @Test("Fallback re-recording age preserves missing-key defaults and explicit tuning")
    func rerecordingAgeRoundTrips() throws {
        let historicalData = Data(
            #"""
            {
              "yearRetrieval": {
                "fallback": {
                  "enabled": true,
                  "yearDifferenceThreshold": 5,
                  "trustAPIScoreThreshold": 70,
                  "maxVerificationAttempts": 3
                }
              }
            }
            """#.utf8
        )

        var decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: historicalData
        )
        #expect(decoded.yearRetrieval.fallback.rerecordingAgeYears == 10)

        decoded.yearRetrieval.fallback.rerecordingAgeYears = 7
        let roundTrip = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTrip.yearRetrieval.fallback.rerecordingAgeYears == 7)
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
