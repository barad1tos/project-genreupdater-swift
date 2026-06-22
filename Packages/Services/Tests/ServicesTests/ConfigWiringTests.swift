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
}
