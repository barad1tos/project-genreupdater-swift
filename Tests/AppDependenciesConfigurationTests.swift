import Core
import DesignUI
import Foundation
import Services
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

    @Test("Preview producer resolves current update behavior and saves a plan")
    func previewProducerSavesPlan() async throws {
        let previousBehavior = UserDefaults.standard.object(forKey: AppStorageKey.defaultUpdateBehavior)
        UserDefaults.standard.set(UpdateBehavior.yearOnly.rawValue, forKey: AppStorageKey.defaultUpdateBehavior)
        defer {
            if let previousBehavior {
                UserDefaults.standard.set(previousBehavior, forKey: AppStorageKey.defaultUpdateBehavior)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStorageKey.defaultUpdateBehavior)
            }
        }

        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 73
        let dependencies = AppDependencies(
            configurationLoader: { configuration },
            configurationSaver: { _ in
                // This test only verifies preview option resolution, not config persistence.
            }
        )
        let probe = PreviewProducerProbe()
        let producer = dependencies.makePreviewProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { await probe.loadTracks() },
            albumContextTracksByTrackID: { await probe.albumContextTracksByTrackID(for: $0) },
            determineTrackChanges: {
                try await probe.determineTrackChanges(
                    track: $0,
                    albumTracks: $1,
                    artistTracks: $2,
                    options: $3
                )
            },
            savePlan: { await probe.savePlan($0, initialDecision: $1) },
            now: { probe.producedAt }
        ))
        let runID = RunID()
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Probe Artist"],
            knownTrackCount: 1,
            createdAt: probe.producedAt,
            reason: "previewProducerTest"
        )

        let production = try await producer(runID, scope)
        let snapshot = await probe.snapshot()

        #expect(production.proposalCount == 1)
        #expect(production.planID == snapshot.savedPlan?.id)
        #expect(snapshot.loadedCount == 1)
        #expect(snapshot.albumContextInputIDs == ["track-1"])
        #expect(snapshot.determinedTrackID == "track-1")
        #expect(snapshot.determinedAlbumIDs == ["album-peer"])
        #expect(snapshot.determinedArtistIDs == ["track-1"])
        #expect(snapshot.options?.updateGenre == false)
        #expect(snapshot.options?.updateYear == true)
        #expect(snapshot.options?.minConfidence == 73)
        #expect(snapshot.savedPlan?.sourceRunID == runID)
        #expect(snapshot.savedPlan?.configuration.updateGenre == false)
        #expect(snapshot.savedPlan?.configuration.updateYear == true)
        #expect(snapshot.savedPlan?.configuration.minConfidence == 73)
        #expect(snapshot.savedDecision?.planID == snapshot.savedPlan?.id)
        #expect(snapshot.savedDecision?.planRevision == snapshot.savedPlan?.revision)
    }

    @Test("Stored latest fix plan is published as projection")
    func publishesLatestFixPlan() async throws {
        let previousBehavior = UserDefaults.standard.object(forKey: AppStorageKey.defaultUpdateBehavior)
        UserDefaults.standard.set(UpdateBehavior.yearOnly.rawValue, forKey: AppStorageKey.defaultUpdateBehavior)
        defer {
            if let previousBehavior {
                UserDefaults.standard.set(previousBehavior, forKey: AppStorageKey.defaultUpdateBehavior)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStorageKey.defaultUpdateBehavior)
            }
        }

        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 73
        let dependencies = AppDependencies(
            configurationLoader: { configuration },
            configurationSaver: { _ in
                // This test reads a stored fix plan without mutating app configuration.
            }
        )
        let plan = try #require(makeStoredFixPlan(configuration: FixPlanConfigurationSnapshot.capture(
            options: PreviewRunOptions.make(
                configuration: configuration,
                updateGenre: false,
                updateYear: true
            ),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_100)
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
        #expect(storedProjection == projection)
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

private actor PreviewProducerProbe {
    nonisolated let producedAt = Date(timeIntervalSince1970: 1_800_000_100)
    private let track = Track(
        id: "track-1",
        name: "Preview Track",
        artist: "Probe Artist",
        album: "Probe Album",
        genre: "Rock",
        year: 2000,
        trackStatus: "purchased"
    )
    private let albumPeer = Track(
        id: "album-peer",
        name: "Album Peer",
        artist: "Probe Artist",
        album: "Probe Album",
        genre: "Rock",
        year: 2001,
        trackStatus: "purchased"
    )
    private var loadCallCount = 0
    private var albumContextInputIDs: [String] = []
    private var determinedTrackID: String?
    private var determinedAlbumIDs: [String] = []
    private var determinedArtistIDs: [String] = []
    private var options: UpdateOptions?
    private var savedPlan: FixPlan?
    private var savedDecision: FixPlanReviewDecision?

    func loadTracks() -> [Track] {
        loadCallCount += 1
        return [track]
    }

    func albumContextTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        albumContextInputIDs = tracks.map(\.id)
        return [track.id: [albumPeer]]
    }

    func determineTrackChanges(
        track: Track,
        albumTracks: [Track],
        artistTracks: [Track],
        options: UpdateOptions
    ) throws -> [ProposedChange] {
        determinedTrackID = track.id
        determinedAlbumIDs = albumTracks.map(\.id)
        determinedArtistIDs = artistTracks.map(\.id)
        self.options = options
        return [
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "2000",
                newValue: "2001",
                confidence: options.minConfidence,
                source: "test"
            )
        ]
    }

    func savePlan(_ plan: FixPlan, initialDecision: FixPlanReviewDecision) {
        savedPlan = plan
        savedDecision = initialDecision
    }

    func snapshot() -> PreviewProducerProbeSnapshot {
        PreviewProducerProbeSnapshot(
            loadedCount: loadCallCount,
            albumContextInputIDs: albumContextInputIDs,
            determinedTrackID: determinedTrackID,
            determinedAlbumIDs: determinedAlbumIDs,
            determinedArtistIDs: determinedArtistIDs,
            options: options,
            savedPlan: savedPlan,
            savedDecision: savedDecision
        )
    }
}

private struct PreviewProducerProbeSnapshot {
    let loadedCount: Int
    let albumContextInputIDs: [String]
    let determinedTrackID: String?
    let determinedAlbumIDs: [String]
    let determinedArtistIDs: [String]
    let options: UpdateOptions?
    let savedPlan: FixPlan?
    let savedDecision: FixPlanReviewDecision?
}

private actor StoredFixPlanStore: FixPlanStore {
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
}

private func makeStoredFixPlan(configuration: FixPlanConfigurationSnapshot) -> FixPlan? {
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
    return FixPlanCapture.makePlan(
        from: [proposal],
        sourceRunID: RunID(),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100),
            reason: "stored-plan-test"
        ),
        configuration: configuration,
        createdAt: Date(timeIntervalSince1970: 1_800_000_100)
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
        .appendingPathComponent("GenreUpdaterAppDependenciesConfigurationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}
