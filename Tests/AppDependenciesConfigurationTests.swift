import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("AppDependencies configuration persistence")
@MainActor
struct AppDependenciesConfigurationTests {
    @Test("Configuration load failure surfaces app error instead of silently using defaults")
    func configurationLoadFailureSurfacesAppError() async {
        let dependencies = AppDependencies(
            configurationLoader: { throw StubConfigurationError.loadFailed },
            configurationSaver: { _ in
                // Load-failure setup must never try to persist configuration.
            }
        )

        #expect(dependencies.configurationLoadIssue?.contains("test configuration load failed") == true)
        #expect(isAppError(dependencies.appState, containing: "test configuration load failed"))

        await dependencies.initialize()

        #expect(isAppError(dependencies.appState, containing: "test configuration load failed"))
        #expect(dependencies.apiOrchestrator == nil)
    }

    @Test("Configuration save failure surfaces app error and skips runtime apply")
    func configurationSaveFailureSurfacesAppErrorAndSkipsRuntimeApply() {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in throw StubConfigurationError.saveFailed }
        )

        let didSave = saveConfiguration(dependencies)

        #expect(didSave == false)
        #expect(isAppError(dependencies.appState, containing: "test configuration save failed"))
        #expect(dependencies.apiOrchestrator == nil)
    }

    @Test("Successful configuration save restores pre-failure app state")
    func successfulConfigurationSaveRestoresPreFailureAppState() {
        var shouldFailSave = true
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                if shouldFailSave {
                    throw StubConfigurationError.saveFailed
                }
            }
        )

        #expect(saveConfiguration(dependencies) == false)
        #expect(isAppError(dependencies.appState, containing: "test configuration save failed"))

        shouldFailSave = false

        #expect(saveConfiguration(dependencies))
        #expect(isAppLoading(dependencies.appState))
    }

    @Test("Configuration mutation save failure rolls back in-memory config")
    func configurationMutationSaveFailureRollsBackInMemoryConfig() {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in throw StubConfigurationError.saveFailed }
        )
        let originalBaseScore = dependencies.config.yearRetrieval.scoring.baseScore

        let didSave = mutateConfiguration(dependencies) { configuration in
            configuration.yearRetrieval.scoring.baseScore = originalBaseScore + 10
        }

        #expect(didSave == false)
        #expect(dependencies.config.yearRetrieval.scoring.baseScore == originalBaseScore)
        #expect(isAppError(dependencies.appState, containing: "test configuration save failed"))
    }

    @Test("Script API priority save failure rolls back in-memory config")
    func scriptAPIPrioritySaveFailureRollsBackInMemoryConfig() {
        let originalPriority = ScriptAPIPriority(
            primary: ["musicbrainz", "discogs"],
            fallback: ["itunes"]
        )
        let dependencies = AppDependencies(
            configurationLoader: {
                var configuration = AppConfiguration()
                configuration.yearRetrieval.scriptAPIPriorities["default"] = originalPriority
                return configuration
            },
            configurationSaver: { _ in throw StubConfigurationError.saveFailed }
        )
        let section = ScriptAPIPrioritySection(dependencies: dependencies)

        section.updateScriptPriority("default", slot: .first, api: .itunes)

        let storedPriority = dependencies.config.yearRetrieval.scriptAPIPriorities["default"]
        #expect(storedPriority?.primary == originalPriority.primary)
        #expect(storedPriority?.fallback == originalPriority.fallback)
        #expect(isAppError(dependencies.appState, containing: "test configuration save failed"))
    }

    @Test("Runtime apply refreshes incremental run tracker path")
    func runtimeApplyRefreshesIncrementalRunTrackerPath() async {
        let logsDirectory = temporaryConfigurationTestDirectory()
        var didSaveConfiguration = false
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                didSaveConfiguration = true
            }
        )
        dependencies.config.paths.logsBaseDirectory = logsDirectory.path
        dependencies.config.logging.lastIncrementalRunFile = "state/last_incremental_run.log"

        #expect(dependencies.saveConfigurationAndApplyRuntime())
        #expect(didSaveConfiguration)

        await dependencies.incrementalRunTracker?.updateLastRunTimestamp()

        let expectedTimestampFile = logsDirectory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("last_incremental_run.log")
        #expect(FileManager.default.fileExists(atPath: expectedTimestampFile.path))
    }

    @Test("Runtime apply wires cleaning edition keywords into year scoring")
    func runtimeApplyWiresCleaningEditionKeywordsIntoYearScoring() {
        var didSaveConfiguration = false
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                didSaveConfiguration = true
            }
        )
        dependencies.config.cleaning.remasterKeywords = ["Anniversary", "Deluxe"]

        #expect(dependencies.saveConfigurationAndApplyRuntime())
        #expect(didSaveConfiguration)

        let scorer = dependencies.yearDeterminator?.scorer
        let scored = [
            makeScoredRelease(year: 2020, score: 94, album: "Clayman (20th Anniversary Edition)"),
            makeScoredRelease(year: 2000, score: 82, album: "Clayman"),
        ]

        let result = scorer?.resolveScores(scored)

        #expect(result?.year == 2000)
    }
}

private enum StubConfigurationError: LocalizedError {
    case loadFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            "test configuration load failed"
        case .saveFailed:
            "test configuration save failed"
        }
    }
}

private func isAppError(_ state: AppState, containing expectedMessage: String) -> Bool {
    guard case let .error(message) = state else {
        return false
    }
    return message.contains(expectedMessage)
}

private func isAppReady(_ state: AppState) -> Bool {
    guard case .ready = state else {
        return false
    }
    return true
}

private func isAppLoading(_ state: AppState) -> Bool {
    guard case .loading = state else {
        return false
    }
    return true
}

private func temporaryConfigurationTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GenreUpdaterAppDependenciesConfigurationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeScoredRelease(
    year: Int,
    score: Int,
    album: String
) -> ScoredRelease {
    let candidate = ReleaseCandidate(
        artist: "Test",
        album: album,
        year: year,
        source: .musicBrainz
    )
    return ScoredRelease(
        candidate: candidate,
        totalScore: score,
        breakdown: ScoreBreakdown()
    )
}
