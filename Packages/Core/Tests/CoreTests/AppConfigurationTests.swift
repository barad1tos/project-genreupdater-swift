import Foundation
import Testing

@testable import Core

@Suite("AppConfiguration — defaults, Codable, nested configs")
struct AppConfigurationTests {

    // MARK: - Default Values

    @Test("Default init creates valid instance with all 8 nested configs")
    func defaultInit() {
        let config = AppConfiguration()

        // All nested configs exist (non-optional, so this is a compile-time guarantee,
        // but verifying key defaults proves the struct initializes correctly)
        #expect(config.applescript.concurrency == 2)
        #expect(config.yearRetrieval.preferredAPI == .musicbrainz)
        #expect(config.genreUpdate.batchSize == 50)
        #expect(config.caching.defaultTTLSeconds == 900)
        #expect(config.processing.batchSize == 50)
        #expect(config.analytics.maxEvents == 10000)
        #expect(config.cleaning.remasterKeywords.count == 7)
        #expect(config.development.debugMode == false)
    }

    // MARK: - JSON Codable Round-Trip

    @Test("Encode to JSON and decode back preserves key fields")
    func jsonRoundTrip() throws {
        let original = AppConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        #expect(decoded.applescript.concurrency == original.applescript.concurrency)
        #expect(decoded.yearRetrieval.preferredAPI == original.yearRetrieval.preferredAPI)
        #expect(decoded.genreUpdate.batchSize == original.genreUpdate.batchSize)
        #expect(decoded.caching.defaultTTLSeconds == original.caching.defaultTTLSeconds)
        #expect(decoded.processing.batchSize == original.processing.batchSize)
        #expect(decoded.analytics.maxEvents == original.analytics.maxEvents)
        #expect(decoded.cleaning.remasterKeywords == original.cleaning.remasterKeywords)
        #expect(decoded.development.debugMode == original.development.debugMode)
    }

    // MARK: - AppleScriptTimeouts Custom Codable

    @Test("AppleScriptTimeouts encodes Duration as seconds with 'Seconds' suffix keys")
    func timeoutsEncodeAsSeconds() throws {
        let timeouts = AppleScriptTimeouts()
        let data = try JSONEncoder().encode(timeouts)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["defaultTimeoutSeconds"] as? Int == 3600)
        #expect(json["fullLibraryFetchSeconds"] as? Int == 3600)
        #expect(json["singleArtistFetchSeconds"] as? Int == 600)
        #expect(json["batchUpdateSeconds"] as? Int == 1800)
        #expect(json["idsBatchFetchSeconds"] as? Int == 120)
    }

    @Test("AppleScriptTimeouts decoding empty JSON uses all defaults")
    func timeoutsDecodeEmptyJSON() throws {
        let json = "{}".data(using: .utf8)!
        let timeouts = try JSONDecoder().decode(AppleScriptTimeouts.self, from: json)

        #expect(timeouts.defaultTimeout == .seconds(3600))
        #expect(timeouts.fullLibraryFetch == .seconds(3600))
        #expect(timeouts.singleArtistFetch == .seconds(600))
        #expect(timeouts.batchUpdate == .seconds(1800))
        #expect(timeouts.idsBatchFetch == .seconds(120))
    }

    @Test("AppleScriptTimeouts decoding partial JSON applies defaults for missing keys")
    func timeoutsDecodePartialJSON() throws {
        let json = """
            {"defaultTimeoutSeconds": 100}
            """.data(using: .utf8)!
        let timeouts = try JSONDecoder().decode(AppleScriptTimeouts.self, from: json)

        #expect(timeouts.defaultTimeout == .seconds(100))
        #expect(timeouts.fullLibraryFetch == .seconds(3600))
        #expect(timeouts.singleArtistFetch == .seconds(600))
        #expect(timeouts.batchUpdate == .seconds(1800))
        #expect(timeouts.idsBatchFetch == .seconds(120))
    }

    // MARK: - PreferredAPI

    @Test("PreferredAPI all cases encode and decode via rawValue",
          arguments: PreferredAPI.allCases)
    func preferredAPIRoundTrip(api: PreferredAPI) throws {
        let data = try JSONEncoder().encode(api)
        let decoded = try JSONDecoder().decode(PreferredAPI.self, from: data)
        #expect(decoded == api)
    }

    @Test("PreferredAPI rawValues match expected strings")
    func preferredAPIRawValues() {
        #expect(PreferredAPI.musicbrainz.rawValue == "musicbrainz")
        #expect(PreferredAPI.discogs.rawValue == "discogs")
        #expect(PreferredAPI.itunes.rawValue == "itunes")
    }

    // MARK: - ScoringConfig

    @Test("ScoringConfig default values")
    func scoringDefaults() {
        let scoring = ScoringConfig()

        #expect(scoring.baseScore == 50)
        #expect(scoring.artistExactMatchBonus == 30)
        #expect(scoring.albumExactMatchBonus == 25)
        #expect(scoring.perfectMatchBonus == 40)
    }

    // MARK: - CleaningConfig

    @Test("CleaningConfig default remasterKeywords has 7 items")
    func cleaningRemasterKeywordsCount() {
        let cleaning = CleaningConfig()
        #expect(cleaning.remasterKeywords.count == 7)
    }

    @Test("CleaningConfig default albumSuffixesToRemove has 5 items")
    func cleaningAlbumSuffixesCount() {
        let cleaning = CleaningConfig()
        #expect(cleaning.albumSuffixesToRemove.count == 5)
    }

    @Test("CleaningConfig default trackCleaningExceptions is empty")
    func cleaningExceptionsEmpty() {
        let cleaning = CleaningConfig()
        #expect(cleaning.trackCleaningExceptions.isEmpty)
    }

    @Test("CleaningConfig default genreMappings is empty")
    func cleaningGenreMappingsEmpty() {
        let cleaning = CleaningConfig()
        #expect(cleaning.genreMappings.isEmpty)
    }

    @Test("CleaningConfig genreMappings round-trip preserves entries")
    func cleaningGenreMappingsRoundTrip() throws {
        var cleaning = CleaningConfig()
        cleaning.genreMappings = [
            "Electronica": "Electronic",
            "Hip Hop": "Hip-Hop",
        ]
        let data = try JSONEncoder().encode(cleaning)
        let decoded = try JSONDecoder().decode(CleaningConfig.self, from: data)
        #expect(decoded.genreMappings == ["Electronica": "Electronic", "Hip Hop": "Hip-Hop"])
    }

    // MARK: - ScriptAPIPriority

    @Test("ScriptAPIPriority with primary only leaves fallback empty")
    func scriptAPIPriorityPrimaryOnly() {
        let priority = ScriptAPIPriority(primary: ["musicbrainz"])

        #expect(priority.primary == ["musicbrainz"])
        #expect(priority.fallback.isEmpty)
    }

    @Test("ScriptAPIPriority with both primary and fallback")
    func scriptAPIPriorityBoth() {
        let priority = ScriptAPIPriority(primary: ["musicbrainz"], fallback: ["discogs"])

        #expect(priority.primary == ["musicbrainz"])
        #expect(priority.fallback == ["discogs"])
    }

    // MARK: - TrackCleaningException

    @Test("TrackCleaningException round-trip preserves fields")
    func trackCleaningExceptionRoundTrip() throws {
        let original = TrackCleaningException(artist: "Pink Floyd", album: "The Wall")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrackCleaningException.self, from: data)

        #expect(decoded.artist == "Pink Floyd")
        #expect(decoded.album == "The Wall")
    }
}
