import Foundation
import Testing
@testable import Core

@Suite("API request policy")
struct APIRequestPolicyTests {
    @Test("Persisted policy preserves missing-key defaults and explicit tuning")
    func decodingAndRoundTrip() throws {
        let defaults = AppConfiguration().yearRetrieval
        #expect(defaults.rateLimits.musicbrainzRequestsPerSecond == 1)
        #expect(defaults.rateLimits.itunesRequestsPerSecond == 10)
        #expect(defaults.providerTimeoutSeconds == 15)

        let legacy = try JSONDecoder().decode(
            APIRateLimits.self,
            from: Data(#"{"discogsRequestsPerMinute":42}"#.utf8)
        )
        #expect(legacy.discogsRequestsPerMinute == 42)
        #expect(legacy.itunesRequestsPerSecond == 10)

        var tuned = YearRetrievalConfig()
        tuned.rateLimits.itunesRequestsPerSecond = 7.5
        tuned.providerTimeoutSeconds = 22.5
        let roundTripped = try JSONDecoder().decode(
            YearRetrievalConfig.self,
            from: JSONEncoder().encode(tuned)
        )
        #expect(roundTripped.rateLimits.itunesRequestsPerSecond == 7.5)
        #expect(roundTripped.providerTimeoutSeconds == 22.5)

        let historical = try JSONDecoder().decode(YearRetrievalConfig.self, from: Data("{}".utf8))
        #expect(historical.providerTimeoutSeconds == 15)
    }

    @Test("Request quotas produce conservative one-token intervals")
    func pacingIntervals() {
        #expect(APIRateLimits.refillMilliseconds(requests: 55, perSeconds: 60) == 1091)
        #expect(APIRateLimits.refillMilliseconds(requests: 1, perSeconds: 1) == 1000)
        #expect(APIRateLimits.refillMilliseconds(requests: 10, perSeconds: 1) == 100)
        #expect(APIRateLimits.refillMilliseconds(requests: 1e-308, perSeconds: 1) == nil)
    }

    @Test("Legacy zero MusicBrainz rate remains a valid persisted boundary")
    func preservesLegacyZeroRate() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-zero-musicbrainz-rate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let legacyJSON = Data(
            #"{"yearRetrieval":{"rateLimits":{"musicbrainzRequestsPerSecond":0}}}"#.utf8
        )
        let historical = try JSONDecoder().decode(AppConfiguration.self, from: legacyJSON)
        try legacyJSON.write(to: configURL, options: .atomic)

        let loaded = try AppConfiguration.load(from: configURL)
        try loaded.save(to: configURL)
        let reloaded = try AppConfiguration.load(from: configURL)

        #expect(historical.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0)
        #expect(loaded.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0)
        #expect(reloaded.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0)
        #expect(APIRateLimits.musicBrainzRate(0) == 1)
        #expect(APIRateLimits.musicBrainzRate(2.5) == 2.5)
    }

    @Test("New provider policy fields reject unsafe persisted values", arguments: PolicyFault.allCases)
    private func rejectsUnsafeValues(_ fault: PolicyFault) {
        var configuration = AppConfiguration()
        fault.apply(to: &configuration)

        #expect(throws: ConfigurationValidationError.self) {
            try configuration.validate()
        }
    }
}

private enum PolicyFault: CaseIterable, Sendable {
    case zeroITunesRate
    case overflowingITunesInterval
    case zeroTimeout
    case overflowingTimeout

    func apply(to configuration: inout AppConfiguration) {
        switch self {
        case .zeroITunesRate:
            configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 0
        case .overflowingITunesInterval:
            configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 1e-308
        case .zeroTimeout:
            configuration.yearRetrieval.providerTimeoutSeconds = 0
        case .overflowingTimeout:
            configuration.yearRetrieval.providerTimeoutSeconds = 1e308
        }
    }
}
