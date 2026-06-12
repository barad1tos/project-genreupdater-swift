import Foundation
import Testing
@testable import Core

@Suite("AppConfiguration — defaults, Codable, nested configs")
struct AppConfigurationTests {
    // MARK: - Default Values

    @Test("Default init creates valid Python parity configuration surface")
    func defaultInit() {
        let config = AppConfiguration()

        // All nested configs exist (non-optional, so this is a compile-time guarantee,
        // but verifying key defaults proves the struct initializes correctly)
        #expect(config.paths.musicLibraryPath == "${HOME}/Music/Music/Music Library.musiclibrary")
        #expect(config.paths.apiCacheFile == "cache/cache.json")
        #expect(config.pythonSettings.preventBytecode)
        #expect(config.runtime.cacheTTLSeconds == 1800)
        #expect(config.runtime.incrementalIntervalMinutes == 1)
        #expect(config.runtime.maxRetries == 3)
        #expect(config.runtime.retryDelaySeconds == 1)
        #expect(config.runtime.maxGenericEntries == 10000)
        #expect(config.applescript.concurrency == 2)
        #expect(config.applescript.rateLimit.enabled)
        #expect(config.applescript.rateLimit.requestsPerWindow == 10)
        #expect(config.applescript.retry.maxRetries == 3)
        #expect(config.applescript.retry.baseDelaySeconds == 1)
        #expect(config.applescript.retry.operationTimeoutSeconds == 60)
        #expect(config.yearRetrieval.preferredAPI == .musicbrainz)
        #expect(config.yearRetrieval.apiAuth.musicBrainzAppName == "MusicGenreUpdater/2.0")
        #expect(config.yearRetrieval.rateLimits.discogsRequestsPerMinute == 55)
        #expect(config.yearRetrieval.rateLimits.concurrentAPICalls == 2)
        #expect(config.yearRetrieval.logic.definitiveScoreThreshold == 50)
        #expect(config.yearRetrieval.logic.definitiveScoreDiff == 15)
        #expect(config.yearRetrieval.reissueDetection.reissueKeywords == ["reissue", "remaster", "remastered"])
        #expect(config.genreUpdate.batchSize == 50)
        #expect(config.caching.defaultTTLSeconds == 900)
        #expect(config.caching.cleanupIntervalSeconds == 300)
        #expect(config.caching.cleanupErrorRetryDelay == 60)
        #expect(config.caching.librarySnapshot.enabled)
        #expect(config.caching.librarySnapshot.deltaEnabled)
        #expect(config.caching.librarySnapshot.cacheFile == "cache/library_snapshot.json")
        #expect(config.caching.librarySnapshot.maxAgeHours == 24)
        #expect(config.caching.librarySnapshot.compress)
        #expect(config.caching.librarySnapshot.compressLevel == 6)
        #expect(config.processing.batchSize == 25)
        #expect(config.processing.delayBetweenBatches == 20)
        #expect(config.processing.cacheTTLDays == 36500)
        #expect(config.processing.pendingVerificationIntervalDays == 30)
        #expect(config.processing.prereleaseHandling == .processEditable)
        #expect(config.analytics.maxEvents == 10000)
        #expect(config.analytics.enabled == false)
        #expect(config.analytics.durationThresholds.mediumMax == 20)
        #expect(config.cleaning.remasterKeywords.count == 9)
        #expect(config.exceptions.trackCleaning.isEmpty)
        #expect(config.artistRenamer.configPath == "artist-renames.yaml")
        #expect(config.artistRenamer.mappings.isEmpty)
        #expect(config.databaseVerification.autoVerifyDays == 7)
        #expect(config.databaseVerification.batchSize == 10)
        #expect(config.pendingVerification.autoVerifyDays == 14)
        #expect(config.reporting.changeDisplayMode == .compact)
        #expect(config.logging.pendingVerificationFile == "csv/pending_year_verification.csv")
        #expect(config.albumTypeDetection.variousArtistsNames.contains("Різні виконавці"))
        #expect(config.experimental.batchUpdatesEnabled == false)
        #expect(config.development.testArtists.isEmpty)
        #expect(config.development.debugMode == false)
    }

    // MARK: - JSON Codable Round-Trip

    @Test("Encode to JSON and decode back preserves key fields")
    func jsonRoundTrip() throws {
        var original = AppConfiguration()
        original.development.testArtists = ["Amon Amarth", "DK Energetyk"]

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        #expect(decoded.applescript.concurrency == original.applescript.concurrency)
        #expect(decoded.yearRetrieval.preferredAPI == original.yearRetrieval.preferredAPI)
        #expect(decoded.yearRetrieval.apiAuth.musicBrainzAppName == original.yearRetrieval.apiAuth.musicBrainzAppName)
        #expect(decoded.genreUpdate.batchSize == original.genreUpdate.batchSize)
        #expect(decoded.caching.defaultTTLSeconds == original.caching.defaultTTLSeconds)
        #expect(decoded.caching.librarySnapshot.cacheFile == original.caching.librarySnapshot.cacheFile)
        #expect(decoded.caching.librarySnapshot.maxAgeHours == original.caching.librarySnapshot.maxAgeHours)
        #expect(decoded.caching.librarySnapshot.compress == original.caching.librarySnapshot.compress)
        #expect(decoded.caching.librarySnapshot.compressLevel == original.caching.librarySnapshot.compressLevel)
        #expect(decoded.processing.batchSize == original.processing.batchSize)
        #expect(decoded.analytics.maxEvents == original.analytics.maxEvents)
        #expect(decoded.cleaning.remasterKeywords == original.cleaning.remasterKeywords)
        #expect(decoded.databaseVerification.batchSize == original.databaseVerification.batchSize)
        #expect(decoded.reporting.problematicAlbumsPath == original.reporting.problematicAlbumsPath)
        #expect(decoded.artistRenamer.mappings == original.artistRenamer.mappings)
        #expect(decoded.albumTypeDetection.soundtrackPatterns == original.albumTypeDetection.soundtrackPatterns)
        #expect(decoded.development.testArtists == original.development.testArtists)
        #expect(decoded.development.debugMode == original.development.debugMode)
    }

    @Test("Decoding partial legacy JSON fills new groups with defaults")
    func partialLegacyJSONDecode() throws {
        let jsonString = """
        {
          "yearRetrieval": {
            "preferredAPI": "discogs"
          },
          "caching": {
            "defaultTTLSeconds": 120
          },
          "processing": {
            "batchSize": 12
          },
          "analytics": {
            "maxEvents": 42
          },
          "exceptions": {
            "track_cleaning": [
              {
                "artist": "Rabbit Junk",
                "album": "Xenospheres"
              }
            ]
          },
          "artistRenamer": {
            "config_path": "legacy-renames.yaml",
            "mappings": {
              "DK Energetyk": "ДК Енергетик"
            }
          }
        }
        """
        let json = Data(jsonString.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)

        #expect(decoded.paths.albumYearsCacheFile == "cache/album_years.csv")
        #expect(decoded.runtime.cacheTTLSeconds == 1800)
        #expect(decoded.runtime.maxRetries == 3)
        #expect(decoded.runtime.retryDelaySeconds == 1)
        #expect(decoded.yearRetrieval.preferredAPI == .discogs)
        #expect(decoded.yearRetrieval.apiAuth.discogsTokenReference == "${DISCOGS_TOKEN}")
        #expect(decoded.yearRetrieval.reissueDetection.reissueKeywords.count == 3)
        #expect(decoded.caching.defaultTTLSeconds == 120)
        #expect(decoded.caching.cleanupErrorRetryDelay == 60)
        #expect(decoded.caching.librarySnapshot.cacheFile == "cache/library_snapshot.json")
        #expect(decoded.caching.librarySnapshot.compress)
        #expect(decoded.caching.librarySnapshot.compressLevel == 6)
        #expect(decoded.processing.batchSize == 12)
        #expect(decoded.processing.prereleaseHandling == .processEditable)
        #expect(decoded.analytics.maxEvents == 42)
        #expect(decoded.analytics.enabled == false)
        #expect(decoded.exceptions.trackCleaning == [
            TrackCleaningException(artist: "Rabbit Junk", album: "Xenospheres"),
        ])
        #expect(decoded.cleaning.trackCleaningExceptions == [
            TrackCleaningException(artist: "Rabbit Junk", album: "Xenospheres"),
        ])
        #expect(decoded.artistRenamer.configPath == "legacy-renames.yaml")
        #expect(decoded.artistRenamer.mappings == ["DK Energetyk": "ДК Енергетик"])
        #expect(decoded.databaseVerification.autoVerifyDays == 7)
        #expect(decoded.reporting.changeDisplayMode == .compact)
    }

    @Test("iTunes search configuration decodes from JSON")
    func iTunesSearchConfigurationDecodes() throws {
        let json = """
        {
          "yearRetrieval": {
            "itunesSearch": {
              "countryCode": "UA",
              "entity": "album",
              "limit": 150,
              "lookupFallbackEnabled": false
            }
          }
        }
        """

        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

        #expect(config.yearRetrieval.itunesSearch.countryCode == "UA")
        #expect(config.yearRetrieval.itunesSearch.entity == "album")
        #expect(config.yearRetrieval.itunesSearch.limit == 150)
        #expect(config.yearRetrieval.itunesSearch.lookupFallbackEnabled == false)
    }

    @Test("Decoding Python-style cache keys preserves snapshot settings")
    func pythonStyleSnapshotCacheKeysDecode() throws {
        let jsonString = """
        {
          "caching": {
            "default_ttl_seconds": 180,
            "album_cache_sync_interval": 240,
            "cleanup_error_retry_delay": 30,
            "cleanup_interval_seconds": 120,
            "negative_result_ttl": 86400,
            "library_snapshot": {
              "enabled": false,
              "delta_enabled": false,
              "cache_file": "cache/custom_snapshot.json",
              "max_age_hours": 12,
              "compress": false,
              "compress_level": 3
            }
          }
        }
        """
        let json = Data(jsonString.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)

        #expect(decoded.caching.defaultTTLSeconds == 180)
        #expect(decoded.caching.albumCacheSyncInterval == 240)
        #expect(decoded.caching.cleanupErrorRetryDelay == 30)
        #expect(decoded.caching.cleanupIntervalSeconds == 120)
        #expect(decoded.caching.negativeResultTTL == 86400)
        #expect(!decoded.caching.librarySnapshot.enabled)
        #expect(!decoded.caching.librarySnapshot.deltaEnabled)
        #expect(decoded.caching.librarySnapshot.cacheFile == "cache/custom_snapshot.json")
        #expect(decoded.caching.librarySnapshot.maxAgeHours == 12)
        #expect(!decoded.caching.librarySnapshot.compress)
        #expect(decoded.caching.librarySnapshot.compressLevel == 3)
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
        let json = Data("{}".utf8)
        let timeouts = try JSONDecoder().decode(AppleScriptTimeouts.self, from: json)

        #expect(timeouts.defaultTimeout == .seconds(3600))
        #expect(timeouts.fullLibraryFetch == .seconds(3600))
        #expect(timeouts.singleArtistFetch == .seconds(600))
        #expect(timeouts.batchUpdate == .seconds(1800))
        #expect(timeouts.idsBatchFetch == .seconds(120))
    }

    @Test("AppleScriptTimeouts decoding partial JSON applies defaults for missing keys")
    func timeoutsDecodePartialJSON() throws {
        let jsonString = """
        {"defaultTimeoutSeconds": 100}
        """
        let json = Data(jsonString.utf8)
        let timeouts = try JSONDecoder().decode(AppleScriptTimeouts.self, from: json)

        #expect(timeouts.defaultTimeout == .seconds(100))
        #expect(timeouts.fullLibraryFetch == .seconds(3600))
        #expect(timeouts.singleArtistFetch == .seconds(600))
        #expect(timeouts.batchUpdate == .seconds(1800))
        #expect(timeouts.idsBatchFetch == .seconds(120))
    }

    // MARK: - PreferredAPI

    @Test(
        "PreferredAPI all cases encode and decode via rawValue",
        arguments: PreferredAPI.allCases
    )
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

        #expect(scoring.baseScore == 10)
        #expect(scoring.artistExactMatchBonus == 20)
        #expect(scoring.albumExactMatchBonus == 25)
        #expect(scoring.perfectMatchBonus == 10)
        #expect(scoring.mbReleaseGroupMatchBonus == 50)
        #expect(scoring.sourceMBBonus == 25)
        #expect(scoring.sourceITunesBonus == -10)
    }

    // MARK: - CleaningConfig

    @Test("CleaningConfig default remasterKeywords has 9 items")
    func cleaningEditionKeywordsCount() {
        let cleaning = CleaningConfig()
        #expect(cleaning.remasterKeywords.count == 9)
    }

    @Test("CleaningConfig default albumSuffixesToRemove has 4 items")
    func cleaningAlbumSuffixesCount() {
        let cleaning = CleaningConfig()
        #expect(cleaning.albumSuffixesToRemove.count == 4)
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
