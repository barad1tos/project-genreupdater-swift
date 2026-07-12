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
        #expect(config.paths.logsBaseDirectory == PathsConfig.defaultLogsBaseDirectory)
        #expect(config.paths.effectiveLogsBaseDirectory == PathsConfig.defaultLogsBaseDirectory)
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
        #expect(config.yearRetrieval.apiAuth.discogsBaseHost == "api.discogs.com")
        #expect(config.yearRetrieval.apiAuth.discogsBaseURL.host == "api.discogs.com")
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
        #expect(config.artistRenamer.mappings.isEmpty)
        #expect(config.databaseVerification.autoVerifyDays == 7)
        #expect(config.databaseVerification.batchSize == 10)
        #expect(config.pendingVerification.autoVerifyDays == 14)
        #expect(config.reporting.changeDisplayMode == .compact)
        #expect(config.reporting.runHistoryLimit == 500)
        #expect(config.logging.pendingVerificationFile == "csv/pending_year_verification.csv")
        #expect(config.albumTypeDetection.variousArtistsNames.contains("Різні виконавці"))
        #expect(config.experimental.batchUpdatesEnabled == false)
        #expect(config.development.testArtists.isEmpty)
        #expect(config.development.debugMode == false)
    }

    @Test("Persisted reporting section without runHistoryLimit decodes with the default")
    func persistedReportingSectionWithoutRunHistoryLimitDecodesWithDefault() throws {
        let json = Data("""
        {"minAttemptsForReport": 5, "changeDisplayMode": "detailed"}
        """.utf8)

        let reporting = try JSONDecoder().decode(ReportingConfig.self, from: json)

        #expect(reporting.minAttemptsForReport == 5)
        #expect(reporting.changeDisplayMode == .detailed)
        #expect(reporting.runHistoryLimit == 500)
    }

    @Test("Explicit runHistoryLimit value decodes")
    func explicitRunHistoryLimitValueDecodes() throws {
        let json = Data(#"{"runHistoryLimit": 200}"#.utf8)

        let reporting = try JSONDecoder().decode(ReportingConfig.self, from: json)

        #expect(reporting.runHistoryLimit == 200)
    }

    @Test("Legacy temporary logs path maps to sandbox-safe app support logs")
    func legacyTemporaryLogsPathUsesAppSupportEffectivePath() {
        var paths = PathsConfig()

        paths.logsBaseDirectory = PathsConfig.legacyTemporaryLogsBaseDirectory

        #expect(paths.effectiveLogsBaseDirectory == PathsConfig.defaultLogsBaseDirectory)
    }

    @Test("Custom logs path stays unchanged")
    func customLogsPathIsPreserved() {
        var paths = PathsConfig()
        let customLogsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-logs")
            .path

        paths.logsBaseDirectory = customLogsPath

        #expect(paths.effectiveLogsBaseDirectory == customLogsPath)
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
        #expect(decoded.yearRetrieval.apiAuth.discogsBaseHost == original.yearRetrieval.apiAuth.discogsBaseHost)
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
            "mappings": {
              "DK Energetyk": "ДК Енергетик"
            }
          }
        }
        """
        let json = Data(jsonString.utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: json)

        #expect(decoded.runtime.cacheTTLSeconds == 1800)
        #expect(decoded.runtime.maxRetries == 3)
        #expect(decoded.runtime.retryDelaySeconds == 1)
        #expect(decoded.yearRetrieval.preferredAPI == .discogs)
        #expect(decoded.yearRetrieval.apiAuth.discogsTokenReference == "${DISCOGS_TOKEN}")
        #expect(decoded.yearRetrieval.apiAuth.discogsBaseHost == "api.discogs.com")
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
        #expect(decoded.artistRenamer.mappings == ["DK Energetyk": "ДК Енергетик"])
        #expect(decoded.databaseVerification.autoVerifyDays == 7)
        #expect(decoded.reporting.changeDisplayMode == .compact)
        #expect(decoded.reporting.runHistoryLimit == 500)
    }

    @Test("Python-era root keys decode into Swift-native configuration owners")
    func pythonRootKeysDecodeIntoSwiftOwners() throws {
        let jsonString = """
        {
          "music_library_path": "/Users/test/Music/Music Library.musiclibrary",
          "apple_scripts_dir": "legacy-applescripts",
          "logs_base_dir": "/tmp/mgu-logs",
          "api_cache_file": "cache/python-cache.json",
          "dry_run": true,
          "cache_ttl_seconds": 77,
          "incremental_interval_minutes": 9,
          "max_retries": 4,
          "retry_delay_seconds": 2.5,
          "max_generic_entries": 321,
          "apple_script_concurrency": 3,
          "apple_script_rate_limit": {
            "enabled": false,
            "requests_per_window": 12,
            "window_size_seconds": 1.5
          },
          "applescript_timeouts": {
            "default": 100,
            "full_library_fetch": 101,
            "single_artist_fetch": 102,
            "batch_update": 103,
            "ids_batch_fetch": 104
          },
          "applescript_retry": {
            "max_retries": 5,
            "base_delay_seconds": 0.25,
            "max_delay_seconds": 7,
            "jitter_range": 0.4,
            "operation_timeout_seconds": 45
          },
          "batch_processing": {
            "ids_batch_size": 44,
            "batch_size": 55
          },
          "year_retrieval": {
            "preferred_api": "discogs",
            "api_auth": {
              "discogs_token": "${DISCOGS_TOKEN}",
              "musicbrainz_app_name": "GenreUpdaterTests/1.0",
              "contact_email": "${CONTACT_EMAIL}"
            },
            "rate_limits": {
              "discogs_requests_per_minute": 50,
              "musicbrainz_requests_per_second": 0.75,
              "concurrent_api_calls": 4
            },
            "processing": {
              "batch_size": 11,
              "delay_between_batches": 12.5,
              "adaptive_delay": false,
              "cache_ttl_days": 365,
              "pending_verification_interval_days": 8,
              "skip_prerelease": false,
              "future_year_threshold": 2,
              "prerelease_recheck_days": 10,
              "prerelease_handling": "mark_only"
            },
            "script_api_priorities": {
              "default": {
                "primary": ["discogs"],
                "fallback": ["musicbrainz", "itunes"]
              }
            }
          },
          "test_artists": ["Паліндром", "Clutch"]
        }
        """

        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: Data(jsonString.utf8)
        )

        #expect(decoded.paths.musicLibraryPath == "/Users/test/Music/Music Library.musiclibrary")
        #expect(decoded.paths.appleScriptsDirectory == "legacy-applescripts")
        #expect(decoded.paths.logsBaseDirectory == PathsConfig.legacyTemporaryLogsBaseDirectory)
        #expect(decoded.paths.effectiveLogsBaseDirectory == PathsConfig.defaultLogsBaseDirectory)
        #expect(decoded.paths.apiCacheFile == "cache/python-cache.json")
        #expect(decoded.runtime.dryRun)
        #expect(decoded.runtime.cacheTTLSeconds == 77)
        #expect(decoded.runtime.incrementalIntervalMinutes == 9)
        #expect(decoded.runtime.maxRetries == 4)
        #expect(decoded.runtime.retryDelaySeconds == 2.5)
        #expect(decoded.runtime.maxGenericEntries == 321)
        #expect(decoded.applescript.concurrency == 3)
        #expect(decoded.applescript.rateLimit.enabled == false)
        #expect(decoded.applescript.rateLimit.requestsPerWindow == 12)
        #expect(decoded.applescript.rateLimit.windowSizeSeconds == 1.5)
        #expect(decoded.applescript.timeouts.defaultTimeout == .seconds(100))
        #expect(decoded.applescript.timeouts.fullLibraryFetch == .seconds(101))
        #expect(decoded.applescript.timeouts.singleArtistFetch == .seconds(102))
        #expect(decoded.applescript.timeouts.batchUpdate == .seconds(103))
        #expect(decoded.applescript.timeouts.idsBatchFetch == .seconds(104))
        #expect(decoded.applescript.retry.maxRetries == 5)
        #expect(decoded.applescript.retry.baseDelaySeconds == 0.25)
        #expect(decoded.applescript.retry.maxDelaySeconds == 7)
        #expect(decoded.applescript.retry.jitterRange == 0.4)
        #expect(decoded.applescript.retry.operationTimeoutSeconds == 45)
        #expect(decoded.applescript.batchProcessing.idsBatchSize == 44)
        #expect(decoded.applescript.batchProcessing.batchSize == 55)
        #expect(decoded.yearRetrieval.preferredAPI == .discogs)
        #expect(decoded.yearRetrieval.apiAuth.discogsTokenReference == "${DISCOGS_TOKEN}")
        #expect(decoded.yearRetrieval.apiAuth.musicBrainzAppName == "GenreUpdaterTests/1.0")
        #expect(decoded.yearRetrieval.apiAuth.contactEmailReference == "${CONTACT_EMAIL}")
        #expect(decoded.yearRetrieval.rateLimits.discogsRequestsPerMinute == 50)
        #expect(decoded.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond == 0.75)
        #expect(decoded.yearRetrieval.rateLimits.concurrentAPICalls == 4)
        #expect(decoded.yearRetrieval.scriptAPIPriorities["default"]?.primary == ["discogs"])
        #expect(decoded.yearRetrieval.scriptAPIPriorities["default"]?.fallback == ["musicbrainz", "itunes"])
        #expect(decoded.processing.batchSize == 11)
        #expect(decoded.processing.delayBetweenBatches == 12.5)
        #expect(decoded.processing.adaptiveDelay == false)
        #expect(decoded.processing.cacheTTLDays == 365)
        #expect(decoded.processing.pendingVerificationIntervalDays == 8)
        #expect(decoded.processing.skipPrerelease == false)
        #expect(decoded.processing.futureYearThreshold == 2)
        #expect(decoded.processing.prereleaseRecheckDays == 10)
        #expect(decoded.processing.prereleaseHandling == .markOnly)
        #expect(decoded.development.testArtists == ["Паліндром", "Clutch"])
    }

    @Test("Development test artists override deprecated top-level test artists")
    func developmentTestArtistsOverrideLegacyTopLevelArtists() throws {
        let jsonString = """
        {
          "development": {
            "test_artists": ["Modern Scope"]
          },
          "test_artists": ["Legacy Scope"]
        }
        """

        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: Data(jsonString.utf8)
        )

        #expect(decoded.development.testArtists == ["Modern Scope"])
    }

    @Test("Canonical grouped settings override deprecated root keys")
    func canonicalGroupedSettingsOverrideDeprecatedRootKeys() throws {
        let canonicalMusicLibraryPath = "Music/Canonical.musiclibrary"
        let legacyMusicLibraryPath = "Music/Legacy.musiclibrary"
        let jsonString = """
        {
          "paths": {
            "music_library_path": "\(canonicalMusicLibraryPath)"
          },
          "music_library_path": "\(legacyMusicLibraryPath)",
          "runtime": {
            "dry_run": false,
            "cache_ttl_seconds": 10
          },
          "dry_run": true,
          "cache_ttl_seconds": 20,
          "applescript": {
            "concurrency": 7,
            "timeouts": {
              "default": 11
            }
          },
          "apple_script_concurrency": 3,
          "applescript_timeout_seconds": 99
        }
        """

        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: Data(jsonString.utf8)
        )

        #expect(decoded.paths.musicLibraryPath == canonicalMusicLibraryPath)
        #expect(decoded.runtime.dryRun == false)
        #expect(decoded.runtime.cacheTTLSeconds == 10)
        #expect(decoded.applescript.concurrency == 7)
        #expect(decoded.applescript.timeouts.defaultTimeout == .seconds(11))
    }

    @Test("Production decoder preserves nested Python-style cache and cleaning keys")
    func configurationDecoderPreservesNestedPythonStyleKeys() throws {
        let jsonString = """
        {
          "caching": {
            "default_ttl_seconds": 180,
            "negative_result_ttl": 86400,
            "library_snapshot": {
              "cache_file": "cache/custom_snapshot.json",
              "max_age_hours": 12
            }
          },
          "cleaning": {
            "track_cleaning": [
              {
                "artist": "Rabbit Junk",
                "album": "Xenospheres"
              }
            ]
          }
        }
        """

        let decoded = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: Data(jsonString.utf8)
        )

        #expect(decoded.caching.defaultTTLSeconds == 180)
        #expect(decoded.caching.negativeResultTTL == 86400)
        #expect(decoded.caching.librarySnapshot.cacheFile == "cache/custom_snapshot.json")
        #expect(decoded.caching.librarySnapshot.maxAgeHours == 12)
        #expect(decoded.cleaning.trackCleaningExceptions == [
            TrackCleaningException(artist: "Rabbit Junk", album: "Xenospheres"),
        ])
    }

    @Test("Load uses the Python-era configuration decoder")
    func loadUsesPythonEraConfigurationDecoder() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-config-load-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: configURL)
        }

        let jsonString = """
        {
          "cache_ttl_seconds": 88,
          "caching": {
            "default_ttl_seconds": 222
          },
          "year_retrieval": {
            "preferred_api": "discogs"
          },
          "development": {
            "test_artists": ["Паліндром"]
          }
        }
        """
        try Data(jsonString.utf8).write(to: configURL, options: .atomic)

        let loaded = try AppConfiguration.load(from: configURL)

        #expect(loaded.runtime.cacheTTLSeconds == 88)
        #expect(loaded.caching.defaultTTLSeconds == 222)
        #expect(loaded.yearRetrieval.preferredAPI == .discogs)
        #expect(loaded.development.testArtists == ["Паліндром"])
    }

    @Test("Python-style cleaning keys decode and drive metadata cleaning")
    func pythonStyleCleaningKeysDecode() throws {
        let jsonString = """
        {
          "cleaning": {
            "remaster_keywords": ["promo", "expanded edition"],
            "album_suffixes_to_remove": ["EP", "Single"],
            "track_cleaning": [
              {
                "artist": "Rabbit Junk",
                "album": "Xenospheres"
              }
            ],
            "genre_mappings": {
              "Electronica": "Electronic"
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(jsonString.utf8))

        #expect(decoded.cleaning.remasterKeywords == ["promo", "expanded edition"])
        #expect(decoded.cleaning.albumSuffixesToRemove == ["EP", "Single"])
        #expect(decoded.cleaning.trackCleaningExceptions == [
            TrackCleaningException(artist: "Rabbit Junk", album: "Xenospheres"),
        ])
        #expect(decoded.cleaning.genreMappings == ["Electronica": "Electronic"])

        let cleaned = cleanNames(
            artist: "Artist",
            trackName: "Song [Promo]",
            albumName: "Album - Single",
            config: decoded.cleaning
        )
        #expect(cleaned.cleanedTrack == "Song")
        #expect(cleaned.cleanedAlbum == "Album")
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

    @Test("Discogs API host decodes from configuration and rejects unsafe hosts")
    func discogsAPIHostConfigurationDecodes() throws {
        let json = """
        {
          "yearRetrieval": {
            "apiAuth": {
              "discogsBaseHost": "SANDBOX.DISCOGS.COM"
            }
          }
        }
        """

        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

        #expect(config.yearRetrieval.apiAuth.discogsBaseHost == "sandbox.discogs.com")
        #expect(config.yearRetrieval.apiAuth.discogsBaseURL.absoluteString == "https://sandbox.discogs.com")
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("https://api.discogs.com") == nil)
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("api.discogs.com/api") == nil)
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("api.discogs.com:443") == nil)
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("localhost") == nil)
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("localhost.localdomain") == nil)
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("music.local") == nil)
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("127.0.0.1") == nil)
        for host in privateNetworkHosts {
            #expect(APIAuthConfig.normalizedDiscogsBaseHost(host) == nil)
        }
        #expect(APIAuthConfig.normalizedDiscogsBaseHost("discogs.example.test") == nil)

        let pythonStyleJSON = """
        {
          "yearRetrieval": {
            "apiAuth": {
              "discogs_base_host": "mirror.discogs.com"
            }
          }
        }
        """
        let pythonStyleConfig = try JSONDecoder().decode(AppConfiguration.self, from: Data(pythonStyleJSON.utf8))
        #expect(pythonStyleConfig.yearRetrieval.apiAuth.discogsBaseHost == "mirror.discogs.com")
    }

    private var privateNetworkHosts: [String] {
        [
            dottedAddress([10, 1, 2, 3]),
            dottedAddress([100, 64, 0, 1]),
            dottedAddress([172, 16, 0, 1]),
            dottedAddress([192, 168, 1, 10]),
        ]
    }

    private func dottedAddress(_ octets: [Int]) -> String {
        octets.map(String.init).joined(separator: ".")
    }

    @Test("Discogs API host decoding fails instead of falling back to production default")
    func discogsAPIHostDecodeRejectsInvalidExplicitConfiguration() {
        let json = """
        {
          "yearRetrieval": {
            "apiAuth": {
              "discogsBaseHost": "https://proxy.example.test/path"
            }
          }
        }
        """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        }
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

    @Test("ID lookup batch range matches the processing boundary")
    func idsBatchRange() {
        #expect(BatchProcessingConfig.idsBatchRange == 1 ... 1000)
        #expect(BatchProcessingConfig.clampIDBatch(0) == 1)
        #expect(BatchProcessingConfig.clampIDBatch(200) == 200)
        #expect(BatchProcessingConfig.clampIDBatch(5000) == 1000)
    }

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
