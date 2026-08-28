import Core
import DesignUI
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("AppDependencies configuration persistence")
@MainActor
struct DependencyConfigTests {
    @Test("Free cache access uses defaults without changing saved settings")
    func freeCacheDefaults() {
        let defaults = AppConfiguration()
        var saved = defaults
        saved.runtime.cacheTTLSeconds = 7
        saved.runtime.maxGenericEntries = 17
        saved.caching.defaultTTLSeconds = 11
        saved.caching.cleanupIntervalSeconds = 13
        saved.caching.negativeResultTTL = 19
        saved.caching.librarySnapshot.enabled = false
        saved.caching.librarySnapshot.maxAgeHours = 23
        saved.processing.cacheTTLDays = 29
        saved.development.testArtists = ["Cache Policy Probe"]

        let free = AppDependencies.effectiveCacheConfiguration(saved, canUseAdvancedCache: false)
        let paid = AppDependencies.effectiveCacheConfiguration(saved, canUseAdvancedCache: true)

        #expect(free.caching.defaultTTLSeconds == defaults.caching.defaultTTLSeconds)
        #expect(free.runtime.cacheTTLSeconds == defaults.runtime.cacheTTLSeconds)
        #expect(free.runtime.maxGenericEntries == defaults.runtime.maxGenericEntries)
        #expect(free.caching.cleanupIntervalSeconds == defaults.caching.cleanupIntervalSeconds)
        #expect(free.processing.cacheTTLDays == defaults.processing.cacheTTLDays)
        #expect(free.caching.negativeResultTTL == defaults.caching.negativeResultTTL)
        #expect(free.caching.librarySnapshot.enabled == defaults.caching.librarySnapshot.enabled)
        #expect(free.caching.librarySnapshot.maxAgeHours == defaults.caching.librarySnapshot.maxAgeHours)
        #expect(free.development.testArtists == saved.development.testArtists)

        #expect(paid.runtime.cacheTTLSeconds == saved.runtime.cacheTTLSeconds)
        #expect(paid.runtime.maxGenericEntries == saved.runtime.maxGenericEntries)
        #expect(paid.caching.defaultTTLSeconds == saved.caching.defaultTTLSeconds)
        #expect(paid.caching.cleanupIntervalSeconds == saved.caching.cleanupIntervalSeconds)
        #expect(paid.processing.cacheTTLDays == saved.processing.cacheTTLDays)
        #expect(paid.caching.negativeResultTTL == saved.caching.negativeResultTTL)
        #expect(paid.caching.librarySnapshot.enabled == saved.caching.librarySnapshot.enabled)
        #expect(paid.caching.librarySnapshot.maxAgeHours == saved.caching.librarySnapshot.maxAgeHours)

        #expect(saved.runtime.cacheTTLSeconds == 7)
        #expect(saved.caching.negativeResultTTL == 19)
    }

    @Test("Subscription transitions apply cache access once without rewriting settings")
    func cacheAccessTransitions() async throws {
        var saved = AppConfiguration()
        saved.runtime.maxGenericEntries = 1
        saved.caching.librarySnapshot.enabled = false
        saved.caching.negativeResultTTL = 7200
        let dependencies = AppDependencies(
            configurationLoader: { saved },
            configurationSaver: { _ in
                Issue.record("Tier transitions must not persist or rewrite configuration")
            }
        )
        let subscription = dependencies.makeSubscriptionService()
        let gate = AppDependencies.makeFeatureGate(for: subscription)
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        dependencies.installTestFeatureGate(gate)
        dependencies.configureLibraryPersistenceForTesting(cache: cache)

        subscription.applyEntitlementState(tier: .weekPass, weekPassExpiry: nil, proAccess: nil)
        await dependencies.runtimeApplyQueue?.value

        await cache.set(key: "paid-a", value: 1, ttl: 3600)
        await cache.set(key: "paid-b", value: 2, ttl: 3600)
        let paidStatistics = await cache.getCacheStatistics()
        #expect(paidStatistics.genericCacheCount == 1)
        #expect(await dependencies.librarySnapshotService?.isEnabled == false)

        subscription.applyEntitlementState(tier: .free, weekPassExpiry: nil, proAccess: nil)
        await dependencies.runtimeApplyQueue?.value

        await cache.set(key: "free-c", value: 3, ttl: 3600)
        let freeStatistics = await cache.getCacheStatistics()
        #expect(freeStatistics.genericCacheCount == 2)
        #expect(await dependencies.librarySnapshotService?.isEnabled == true)
        #expect(dependencies.config.runtime.maxGenericEntries == 1)
        #expect(dependencies.config.caching.librarySnapshot.enabled == false)
        #expect(dependencies.config.caching.negativeResultTTL == 7200)
    }

    @Test("Runtime configuration preserves the analytics process session")
    func analyticsSessionContinuity() async throws {
        let configuration = AppConfiguration()
        let dependencies = AppDependencies(
            configurationLoader: { configuration },
            configurationSaver: { _ in
                Issue.record("Runtime analytics apply must not persist configuration")
            }
        )
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let recorder = AnalyticsRecorder(store: cache, configuration: configuration.analytics)
        dependencies.configureLibraryPersistenceForTesting(cache: cache)
        dependencies.installTestAnalyticsRecorder(recorder)

        _ = try dependencies.applyRuntimeConfigurationHead()

        #expect(dependencies.analyticsService === recorder)
    }

    @Test("Invalid library sync delay reports an error without applying runtime consumers")
    func invalidSyncDelayIsAtomic() async throws {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                Issue.record("Runtime apply must not persist configuration")
            }
        )
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let recorder = AnalyticsRecorder(store: cache, configuration: dependencies.config.analytics)
        dependencies.configureLibraryPersistenceForTesting(cache: cache)
        dependencies.installTestAnalyticsRecorder(recorder)
        _ = try dependencies.applyRuntimeConfigurationHead()
        let initialTracker = try #require(dependencies.incrementalRunTracker)
        let initialEditionKeywords = try #require(dependencies.yearDeterminator).scorer.editionKeywords
        let initialAPIOrchestrator = try #require(dependencies.apiOrchestrator)
        dependencies.setDiscogsIssue(.missingToken)

        dependencies.config.librarySync.conflictDelaySeconds = .nan
        dependencies.config.cleaning.editionMarkers = ["Mutation Probe"]
        dependencies.config.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        dependencies.config.analytics.enabled = true

        await dependencies.applyRuntimeConfigurationAndWait()

        #expect(isAppError(dependencies.appState, containing: "Failed to apply runtime configuration"))
        #expect(isAppError(dependencies.appState, containing: "cannot be represented safely"))
        #expect(await recorder.projection(for: .currentSession).state == .disabled)
        #expect(dependencies.incrementalRunTracker === initialTracker)
        #expect(dependencies.yearDeterminator?.scorer.editionKeywords == initialEditionKeywords)
        #expect(dependencies.apiOrchestrator === initialAPIOrchestrator)
        #expect(dependencies.discogsCredentialIssue == .missingToken)
        #expect(dependencies.isDiscogsAccessAvailable == false)
    }

    @Test("Configuration load failure surfaces app error instead of silently using defaults")
    func configurationLoadFailureSurfacesAppError() async {
        let dependencies = AppDependencies(
            configurationLoader: { throw StubConfigurationError.loadFailed },
            configurationSaver: { _ in
                // Load-failure setup must never try to persist configuration.
            }
        )

        #expect(dependencies.configurationLoadIssue?.contains("test configuration load failed") == true)
        #expect(dependencies.configurationLoadIssue?.contains(AppConfiguration.configFileURL.path) == true)
        #expect(dependencies.configurationLoadIssue?.contains("Try Again") == true)
        #expect(isAppError(dependencies.appState, containing: "test configuration load failed"))

        await dependencies.initialize()

        #expect(isAppError(dependencies.appState, containing: "test configuration load failed"))
        #expect(dependencies.apiOrchestrator == nil)
    }

    @Test("Default test dependencies keep persistence in memory")
    func usesMemoryStoresInTests() async throws {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })
        let container = try #require(dependencies.modelContainer)
        let configuration = AppConfiguration()
        let cache = try makeProcessCache(
            configuration: configuration,
            apiResultTTL: AppDependencies.apiResultCacheTTL(configuration: configuration)
        )

        #expect(!container.configurations.isEmpty)
        #expect(container.configurations.first?.isStoredInMemoryOnly == true)
        #expect(await cache.storagePath == ":memory:")
    }

    @Test("Invalid numeric configuration blocks service initialization with the field error")
    func invalidNumericConfigurationBlocksInitialization() async throws {
        var invalidConfiguration = AppConfiguration()
        invalidConfiguration.genreUpdate.batchSize = 0
        let invalidData = try JSONEncoder().encode(invalidConfiguration)
        let dependencies = AppDependencies(
            configurationLoader: {
                try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: invalidData)
            },
            configurationSaver: { _ in
                Issue.record("A failed configuration load must not save fallback defaults")
            }
        )

        #expect(dependencies.configurationLoadIssue?.contains("genreUpdate.batchSize") == true)
        #expect(isAppError(dependencies.appState, containing: "must be at least 1"))

        await dependencies.initialize()

        #expect(dependencies.apiOrchestrator == nil)
        #expect(dependencies.trackStore == nil)
    }

    @Test("Artist conflict UI refreshes after a failed retry")
    func retryRefreshesConflict() async throws {
        var initialConflict = AppConfiguration()
        initialConflict.artistRenamer.mappings = [
            " oldartist  ": "Second",
            "OldArtist": "First",
        ]
        let initialData = try JSONEncoder().encode(initialConflict)
        var retryConflict = AppConfiguration()
        retryConflict.artistRenamer.mappings = [
            "newartist": "Fourth",
            "NewArtist": "Third",
        ]
        let retryData = try JSONEncoder().encode(retryConflict)
        let loader = RetryConfigurationLoader()
        loader.result = Result {
            try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: initialData)
        }
        let dependencies = AppDependencies(
            configurationLoader: { try loader.load() },
            configurationSaver: { _ in
                Issue.record("A failed configuration retry must not save fallback defaults")
            }
        )

        #expect(dependencies.configurationLoadIssue?.contains(#"" oldartist  ""#) == true)
        #expect(isAppError(dependencies.appState, containing: #"" oldartist  ""#))
        #expect(isAppError(dependencies.appState, containing: #""OldArtist""#))
        #expect(isAppError(dependencies.appState, containing: "Try Again"))

        loader.result = Result {
            try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: retryData)
        }

        await dependencies.retryInitialization()

        #expect(loader.callCount == 2)
        #expect(isAppError(dependencies.appState, containing: #""newartist""#))
        #expect(isAppError(dependencies.appState, containing: #""NewArtist""#))
        #expect(isAppError(dependencies.appState, containing: "Try Again"))
        #expect(!isAppError(dependencies.appState, containing: #""OldArtist""#))
        #expect(dependencies.apiOrchestrator == nil)
    }

    @Test("Retry reloads a corrected numeric configuration")
    func retryReloadsCorrectedConfiguration() async {
        let loader = RetryConfigurationLoader()
        let dependencies = AppDependencies(
            configurationLoader: { try loader.load() },
            configurationSaver: { _ in
                // Retry exercises only the persisted load boundary.
            }
        )
        #expect(dependencies.configurationLoadIssue != nil)
        var corrected = AppConfiguration()
        corrected.development.testArtists = ["Retry Probe"]
        loader.result = .success(corrected)

        await dependencies.retryInitialization()

        #expect(loader.callCount == 2)
        #expect(dependencies.configurationLoadIssue == nil)
        #expect(dependencies.config.development.testArtists == ["Retry Probe"])
    }

    @Test("Failed retry keeps configuration recovery instructions")
    func keepsRetryGuidance() async {
        let loader = RetryConfigurationLoader()
        let dependencies = AppDependencies(
            configurationLoader: { try loader.load() },
            configurationSaver: { _ in
                Issue.record("A failed retry must not persist configuration")
            }
        )

        await dependencies.retryInitialization()

        #expect(loader.callCount == 2)
        #expect(dependencies.configurationLoadIssue?.contains(AppConfiguration.configFileURL.path) == true)
        #expect(dependencies.configurationLoadIssue?.contains("Try Again") == true)
    }

    @Test("Workflow prerequisite failure names the missing services")
    func workflowPrerequisiteFailureNamesTheMissingServices() {
        let error = AppInitializationError.missingWorkflowPrerequisites(["apiOrchestrator", "trackStore"])

        #expect(error.errorDescription == "Cannot initialize workflow services — missing: apiOrchestrator, trackStore")
    }

    @Test("Configuration save failure surfaces app error and skips runtime apply")
    func configurationSaveFailureSurfacesAppErrorAndSkipsRuntimeApply() {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in throw StubConfigurationError.saveFailed }
        )

        let didSave = dependencies.persistConfiguration()

        #expect(didSave == .unavailable)
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

        #expect(dependencies.persistConfiguration() == .unavailable)
        #expect(isAppError(dependencies.appState, containing: "test configuration save failed"))

        shouldFailSave = false

        #expect(dependencies.persistConfiguration() == .saved)
        #expect(isAppLoading(dependencies.appState))
    }

    @Test("Configuration mutation save failure rolls back in-memory config")
    func configurationMutationSaveFailureRollsBackInMemoryConfig() {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in throw StubConfigurationError.saveFailed }
        )
        let originalBaseScore = dependencies.config.yearRetrieval.scoring.baseScore

        let status = mutateConfiguration(dependencies) { configuration in
            configuration.yearRetrieval.scoring.baseScore = originalBaseScore + 10
        }

        #expect(status == .temporaryUnavailable)
        #expect(dependencies.config.yearRetrieval.scoring.baseScore == originalBaseScore)
        #expect(isAppError(dependencies.appState, containing: "test configuration save failed"))
    }

    @Test("Invalid numeric settings roll back live and persisted configuration")
    func invalidNumericSettingsRollBackConfiguration() throws {
        let directory = temporaryConfigurationTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurationURL = directory.appendingPathComponent("config.json")
        let initialConfiguration = AppConfiguration()
        let initialData = try JSONEncoder().encode(initialConfiguration)
        try initialData.write(to: configurationURL, options: .atomic)

        let dependencies = AppDependencies(
            configurationLoader: { initialConfiguration },
            configurationSaver: { configuration in
                let data = try JSONEncoder().encode(configuration)
                _ = try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: data)
                try data.write(to: configurationURL, options: .atomic)
            }
        )

        let status = mutateConfiguration(dependencies) { configuration in
            configuration.runtime.maxGenericEntries = 0
        }

        #expect(status == .rejectedInvalid)
        #expect(dependencies.config.runtime.maxGenericEntries == 10000)
        #expect(dependencies.config.revision == 0)
        #expect(isAppError(dependencies.appState, containing: "runtime.maxGenericEntries"))

        let persistedData = try Data(contentsOf: configurationURL)
        let persisted = try AppConfiguration.configurationDecoder().decode(
            AppConfiguration.self,
            from: persistedData
        )
        #expect(persisted.runtime.maxGenericEntries == 10000)
        #expect(persisted.revision == 0)
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

        #expect(dependencies.persistConfiguration() == .saved)
        await dependencies.applyRuntimeConfigurationAndWait()
        #expect(didSaveConfiguration)

        await dependencies.incrementalRunTracker?.updateLastRunTimestamp()

        let expectedTimestampFile = logsDirectory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("last_incremental_run.log")
        #expect(FileManager.default.fileExists(atPath: expectedTimestampFile.path))

        // A second apply rebuilds the tracker AND refreshes the chrome
        // due-fact cache from the persisted timestamp (D6): drop the
        // RuntimeApply refresh or the helper copy and this goes nil.
        dependencies.lastIncrementalRunTimestamp = nil
        await dependencies.applyRuntimeConfigurationAndWait()
        #expect(dependencies.lastIncrementalRunTimestamp != nil)
    }

    @Test("Workflow composition applies configured genre mappings to incremental scope")
    func compositionGenreMappings() async {
        let logsDirectory = temporaryConfigurationTestDirectory()
        let dependencies = AppDependencies(
            configurationLoader: {
                var configuration = AppConfiguration()
                configuration.cleaning.genreMappings = ["Electronic": "Electronica"]
                return configuration
            },
            configurationSaver: { configuration in
                _ = configuration
            }
        )
        let tracker = IncrementalRunTracker(
            logsBaseDirectory: logsDirectory.path,
            lastIncrementalRunFile: "last-run.txt",
            currentDate: { Date(timeIntervalSince1970: 1000) }
        )
        dependencies.installTestIncrementalRunTracker(tracker)
        await tracker.updateLastRunTimestamp()
        let workflow = makeWorkflowFixture()
        let workflowDependencies = dependencies.makeWorkflowDependencies(
            coordinator: workflow.coordinator,
            pipeline: ChangePreviewPipeline(),
            processor: workflow.batchProcessor
        )
        let track = Track(
            id: "mapped",
            name: "Mapped Genre",
            artist: "Artist",
            album: "Album",
            genre: "Electronic",
            dateAdded: Date(timeIntervalSince1970: 500)
        )

        let resolved = await workflowDependencies.resolveIncrementalTracks(
            [track],
            IncrementalTrackScopeOptions(updateGenre: true)
        )

        #expect(resolved.map(\.id) == ["mapped"])
    }

    @Test("Runtime apply wires cleaning edition keywords into year scoring")
    func appliesScoringKeywords() async {
        var didSaveConfiguration = false
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                didSaveConfiguration = true
            }
        )
        dependencies.config.cleaning.editionMarkers = ["Anniversary", "Deluxe"]
        dependencies.config.albumTypeDetection.soundtrackPatterns = ["Game Score"]
        dependencies.config.yearRetrieval.logic.definitiveScoreDiff = 15

        #expect(dependencies.persistConfiguration() == .saved)
        await dependencies.applyRuntimeConfigurationAndWait()
        #expect(didSaveConfiguration)
        #expect(dependencies.yearDeterminator?.scorer.editionKeywords == ["Anniversary", "Deluxe"])
        #expect(dependencies.yearDeterminator?.scorer.soundtrackPatterns == ["Game Score"])

        let scoredReleases = [
            makeScoredRelease(year: 2020, score: 94, album: "Clayman (20th Anniversary Edition)"),
            makeScoredRelease(year: 2000, score: 82, album: "Clayman"),
        ]
        let result = dependencies.yearDeterminator?.scorer.resolveScores(scoredReleases)

        #expect(result?.year == 2000)
    }

    @Test("Advanced JSON editor accepts Python-era configuration keys")
    func advancedJSONEditorAcceptsPythonEraConfigurationKeys() throws {
        let jsonString = """
        {
          "cache_ttl_seconds": 444,
          "year_retrieval": {
            "preferred_api": "discogs",
            "api_auth": {
              "musicbrainz_app_name": "GenreUpdaterTests/1.0"
            }
          },
          "test_artists": ["Паліндром"]
        }
        """

        let configuration = try AdvancedTab.decodeConfiguration(jsonString)

        #expect(configuration.runtime.cacheTTLSeconds == 444)
        #expect(configuration.yearRetrieval.preferredAPI == .discogs)
        #expect(configuration.yearRetrieval.apiAuth.musicBrainzAppName == "GenreUpdaterTests/1.0")
        #expect(configuration.development.testArtists == ["Паліндром"])
    }

    @Test("DesignUI update behavior raw values stay aligned with app storage")
    func designUpdateBehaviorRawValuesStayAlignedWithAppStorage() {
        let pairs: [(app: UpdateBehavior, design: DesignUpdateBehavior)] = [
            (.genreOnly, .genreOnly),
            (.yearOnly, .yearOnly),
            (.both, .both),
        ]

        for pair in pairs {
            #expect(pair.app.rawValue == pair.design.rawValue)
            #expect(UpdateBehavior(rawValue: pair.design.rawValue) == pair.app)
            #expect(DesignUpdateBehavior(rawValue: pair.app.rawValue) == pair.design)
        }
    }

    @Test("Stored latest fix plan is published as projection")
    func publishesLatestFixPlan() async throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 73
        let dependencies = AppDependencies(
            configurationLoader: { configuration },
            configurationSaver: { _ in
                // This test reads a stored fix plan without mutating app configuration.
            }
        )
        let plan = try #require(try makeStoredFixPlan(configuration: dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 1_800_000_100),
            hasDiscogsAccess: true
        )))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: StoredFixPlanStore(plan: plan, decision: decision)
        )

        let projection = await dependencies.refreshFixPlanProjection()
        let storedProjection = await dependencies.projectionStore.fixPlanProjection()

        #expect(projection.planID == plan.id)
        #expect(projection.sourceRunID == plan.sourceRunID)
        #expect(projection.itemCount == 1)
        #expect(projection.acceptedCount == 1)
        #expect(projection.status == .ready)
        #expect(projection.stalenessReasons.isEmpty)
        #expect(storedProjection == projection)

        dependencies.setDiscogsIssue(.missingToken)
        let staleProjection = await dependencies.refreshFixPlanProjection()
        #expect(staleProjection.status == .stale)
        #expect(staleProjection.stalenessReasons == [.configurationChanged])
    }

    @Test("An album-targeted fix plan stays fresh under an unchanged configuration")
    func targetedPlanStaysFresh() async throws {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // This test reads a stored fix plan without mutating app configuration.
            }
        )
        // The target is the plan's identity, not a live setting: staleness
        // must not flag it as configuration drift.
        let plan = try #require(try makeStoredFixPlan(configuration: dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 1_800_000_100),
            hasDiscogsAccess: true,
            albumTarget: FixPlanAlbumTarget(artist: "Clutch", album: "Blast Tyrant")
        )))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: StoredFixPlanStore(plan: plan, decision: decision)
        )

        let projection = await dependencies.refreshFixPlanProjection()

        #expect(projection.status == .ready)
        #expect(projection.stalenessReasons.isEmpty)
    }

    @Test("Missing fix plan store keeps projection empty")
    func emptyFixPlanWithoutStore() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // This test verifies startup projection state before persistence is wired.
            }
        )

        let projection = await dependencies.refreshFixPlanProjection()

        #expect(projection.status == .empty)
        #expect(projection.operationalIssues.isEmpty)
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

@MainActor
private final class RetryConfigurationLoader {
    var result: Result<AppConfiguration, any Error> = .failure(StubConfigurationError.loadFailed)
    private(set) var callCount = 0

    func load() throws -> AppConfiguration {
        callCount += 1
        return try result.get()
    }
}

actor StoredFixPlanStore: FixPlanStore {
    private let plan: FixPlan?
    private var decision: FixPlanReviewDecision?

    init(plan: FixPlan?, decision: FixPlanReviewDecision?) {
        self.plan = plan
        self.decision = decision
    }

    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {
        // Projection refresh tests exercise reads only; writes are intentionally unused.
    }

    func plan(id: FixPlanID, revision: FixPlanRevision) async throws -> FixPlan? {
        guard plan?.id == id, plan?.revision == revision else { return nil }
        return plan
    }

    func latestPlan() async throws -> FixPlan? {
        plan
    }

    func currentDecision(for planID: FixPlanID) async throws -> FixPlanReviewDecision? {
        guard plan?.id == planID else { return nil }
        return decision
    }

    func recordDecision(_ decision: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        self.decision = decision
        return .saved(decision)
    }

    func deletePlans(notIn _: Set<FixPlanID>) async throws -> Int {
        0
    }
}

func makeStoredFixPlan(configuration: FixPlanConfig) throws -> FixPlan? {
    let track = Track(
        id: "stored-track",
        name: "Stored Track",
        artist: "Stored Artist",
        album: "Stored Album",
        genre: "Rock",
        year: 2000,
        trackStatus: "purchased"
    )
    let proposal = ProposedChange(
        track: track,
        changeType: .yearUpdate,
        oldValue: "2000",
        newValue: "2001",
        confidence: 73,
        source: "test"
    )
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_100),
        reason: "stored-plan-test"
    )
    return try FixPlanCapture.makePlan(
        from: [proposal],
        sourceRunID: RunID(),
        evidence: .init(
            scope: scope,
            admission: workflowProcessingAdmission(scope: scope)
        ),
        configuration: configuration,
        createdAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
}

private func makeScoredRelease(
    year: Int,
    score: Int,
    album: String
) -> ScoredRelease {
    var breakdown = ScoreBreakdown()
    breakdown.base = score
    return ScoredRelease(
        candidate: ReleaseCandidate(
            artist: "Test",
            album: album,
            year: year,
            source: .musicBrainz
        ),
        totalScore: score,
        breakdown: breakdown
    )
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
        .appendingPathComponent("GenreUpdaterDependencyConfigTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}
