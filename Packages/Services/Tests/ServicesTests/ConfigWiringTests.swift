import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Runtime config wiring")
struct ConfigWiringTests {
    @Test("API source priorities use script-specific configuration")
    func apiSourcePrioritiesUseScriptConfiguration() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.preferredAPI = .musicbrainz
        configuration.yearRetrieval.scriptAPIPriorities = [
            "cyrillic": ScriptAPIPriority(
                primary: ["itunes", "musicbrainz"],
                fallback: ["discogs"]
            ),
        ]

        let priorities = APISourcePriorityConfiguration(configuration: configuration)

        #expect(
            priorities.orderedSources(
                artist: "Паліндром",
                album: "Найліпші питання"
            ) == [.itunes, .musicBrainz, .discogs]
        )
        #expect(
            priorities.orderedSources(
                artist: "Clutch",
                album: "Pure Rock Fury"
            ) == [.musicBrainz, .discogs, .itunes]
        )
    }

    @Test("Batch processing config follows processing settings and restricted scope")
    func batchProcessingConfigFollowsProcessingSettingsAndRestrictedScope() {
        var configuration = AppConfiguration()
        configuration.processing.batchSize = 41
        configuration.processing.delayBetweenBatches = 2.5
        configuration.processing.adaptiveDelay = true

        let fullScope = BatchProcessingConfiguration(
            configuration: configuration,
            isScopeRestricted: false
        )
        let restrictedScope = BatchProcessingConfiguration(
            configuration: configuration,
            isScopeRestricted: true
        )

        #expect(fullScope.batchSize == 41)
        #expect(fullScope.delayBetweenBatchesMilliseconds == 2500)
        #expect(fullScope.adaptiveDelay)
        #expect(restrictedScope.batchSize == 41)
        #expect(restrictedScope.delayBetweenBatchesMilliseconds == 0)
        #expect(restrictedScope.adaptiveDelay == false)
    }

    @Test("Python-era configuration keys feed runtime configuration owners")
    func pythonEraConfigurationKeysFeedRuntimeConfigurationOwners() throws {
        let jsonString = """
        {
          "test_artists": ["Паліндром"],
          "batch_processing": {
            "ids_batch_size": 22,
            "batch_size": 44
          },
          "applescript_timeouts": {
            "full_library_fetch": 321,
            "ids_batch_fetch": 45
          },
          "year_retrieval": {
            "preferred_api": "discogs",
            "script_api_priorities": {
              "cyrillic": {
                "primary": ["itunes"],
                "fallback": ["discogs"]
              }
            },
            "processing": {
              "batch_size": 13,
              "delay_between_batches": 1.25,
              "adaptive_delay": true,
              "min_confidence_to_cache": 77,
              "skip_prerelease": false,
              "prerelease_handling": "mark_only",
              "prerelease_recheck_days": 10
            }
          }
        }
        """
        let configuration = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: Data(jsonString.utf8)
        )

        let updateRuntime = UpdateRuntimeConfiguration(configuration: configuration)
        #expect(updateRuntime.testArtists == ["Паліндром"])
        #expect(updateRuntime.minimumConfidenceToCache == 77)
        #expect(updateRuntime.skipPrerelease == false)
        #expect(updateRuntime.prereleaseHandling == .markOnly)
        #expect(updateRuntime.prereleaseRecheckDays == 10)

        let syncRuntime = LibrarySyncRuntimeConfiguration(configuration: configuration)
        #expect(syncRuntime.idsBatchSize == 22)
        #expect(syncRuntime.fullLibraryFetchTimeout == .seconds(321))
        #expect(syncRuntime.idsBatchFetchTimeout == .seconds(45))

        let sourcePriority = APISourcePriorityConfiguration(configuration: configuration)
        #expect(sourcePriority.orderedSources(artist: "Паліндром", album: "Найліпші питання") == [
            .itunes,
            .discogs,
            .musicBrainz,
        ])

        let batchProcessing = BatchProcessingConfiguration(configuration: configuration)
        #expect(batchProcessing.batchSize == 13)
        #expect(batchProcessing.delayBetweenBatchesMilliseconds == 0)
        #expect(batchProcessing.adaptiveDelay == false)
    }

    @Test("API orchestrator config maps year-retrieval and runtime settings")
    func apiOrchestratorConfigMapsYearRetrievalAndRuntimeSettings() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.fallback.maxVerificationAttempts = 9
        configuration.caching.negativeResultTTL = 12345
        configuration.yearRetrieval.rateLimits.concurrentAPICalls = 7
        configuration.runtime.maxRetries = 4
        configuration.runtime.retryDelaySeconds = 2.5
        configuration.yearRetrieval.preferredAPI = .discogs

        let orchestrator = APIOrchestratorConfiguration(configuration: configuration)

        #expect(orchestrator.maxVerificationAttempts == 9)
        #expect(orchestrator.negativeResultTTL == 12345)
        #expect(orchestrator.maxConcurrentSourceCalls == 7)
        #expect(orchestrator.maxAPIRetries == 4)
        #expect(orchestrator.apiRetryDelaySeconds == 2.5)
        #expect(
            orchestrator.sourcePriorityConfiguration
                .orderedSources(artist: "Clutch", album: "Pure Rock Fury").first == .discogs
        )
        // Runtime injectables stay unset; the composition root supplies them.
        #expect(orchestrator.cache == nil)
        #expect(orchestrator.disabledSources.isEmpty)
    }
}
