import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Fix plan write factory")
struct FixPlanFactoryTests {
    @Test("App dependency factory enforces recovery admission")
    @MainActor
    func enforcesRecovery() async throws {
        let item = makeItem()
        let plan = makePlan(item)
        let decision = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: .initial,
            decidedAt: Date(timeIntervalSince1970: 110),
            itemDecisions: [FixPlanItemDecision(itemID: item.id, verdict: .accepted)]
        )
        let store = FactoryPlanStore(plan: plan, decision: decision)
        let scriptClient = ScriptSpy()
        await scriptClient.setTracks([Track(
            id: "AS-1",
            name: "Track 1",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "AS-1"
        )])
        let mapper = TrackIDMapper()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixPlanFactoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(fixedTier: .pro)
        )
        let undo = UndoCoordinator(scriptBridge: scriptClient, directory: directory)
        let api = DashboardStateAPIService()
        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: APIOrchestrator(services: APIOrchestratorServices(
                    musicBrainz: api,
                    discogs: api,
                    appleMusic: api
                )),
                scriptBridge: scriptClient,
                trackStore: FactoryTrackStore(),
                cache: FactoryCache(),
                undoCoordinator: undo,
                idMapper: mapper
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(areBatchUpdatesEnabled: false)
        )
        let heldRecord = sampleRunRecord(state: .recoverable, finishedAt: nil)
        let runStore = RunRecordStoreStub(reportPages: [
            RunReportPage(records: [heldRecord], skippedCorruptedCount: 0),
            RunReportPage(records: [], skippedCorruptedCount: 0),
            RunReportPage(records: [], skippedCorruptedCount: 0)
        ])
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })
        dependencies.installTestWrites(TestWriteServices(
            batchProcessor: processor,
            updateCoordinator: coordinator,
            mapper: mapper,
            fixPlanStore: store,
            runRecordStore: runStore,
            script: FixPlanWrite.ScriptAccess(client: scriptClient, batchSize: { 10 })
        ))
        let runner = try #require(dependencies.makeWriteRunner())
        let target = FixPlanWriteTarget(
            planID: plan.id,
            planRevision: plan.revision,
            decisionRevision: decision.revision
        )

        await #expect(throws: WriteAdmissionError.self) {
            _ = try await runner(target)
        }
        #expect(await scriptClient.fetchCalls.isEmpty)

        await scriptClient.returnUnknownOutcome()
        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await runner(target)
        }
        let recoveryID = try #require(await processor.recoveryHoldID())
        let fetchCount = await scriptClient.fetchCalls.count
        await #expect(throws: BatchProcessorError.self) {
            _ = try await runner(target)
        }
        #expect(await scriptClient.fetchCalls.count == fetchCount)
        try await processor.clearRecovery(batchID: recoveryID)
    }
}

private actor ScriptSpy: AppleScriptClient {
    private var tracksByID: [String: Track] = [:]
    private(set) var fetchCalls: [(trackIDs: [String], batchSize: Int)] = []
    private var shouldReturnUnknown = false

    func setTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func initialize() async throws {}

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        fetchCalls.append((trackIDs, batchSize))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        Array(tracksByID.keys)
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws
        -> AppleScriptWriteResult {
        if shouldReturnUnknown {
            throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        }
        return .noChange
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {}

    func returnUnknownOutcome() {
        shouldReturnUnknown = true
    }
}

private actor FactoryPlanStore: FixPlanStore {
    let storedPlan: FixPlan
    let storedDecision: FixPlanReviewDecision

    init(plan: FixPlan, decision: FixPlanReviewDecision) {
        storedPlan = plan
        storedDecision = decision
    }

    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {}
    func plan(id: FixPlanID, revision: FixPlanRevision) async throws -> FixPlan? {
        storedPlan.id == id && storedPlan.revision == revision ? storedPlan : nil
    }
    func latestPlan() async throws -> FixPlan? {
        storedPlan
    }
    func currentDecision(for planID: FixPlanID) async throws -> FixPlanReviewDecision? {
        storedPlan.id == planID ? storedDecision : nil
    }
    func recordDecision(_ decision: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        .saved(decision)
    }
}

private actor FactoryTrackStore: TrackStateStore {
    func initialize() async throws {}
    func loadAllTracks() async throws -> [Track] {
        []
    }
    func saveTracks(_: [Track]) async throws {}
    func deleteTrackIDs(_: [String]) async throws -> Int {
        0
    }
    func getTrack(byID _: String) async throws -> Track? {
        nil
    }
    func updateTrackProcessingState(id _: String, genreUpdated _: Bool?, yearUpdated _: Bool?) async throws {}
    func getUnprocessedTracks() async throws -> [Track] {
        []
    }
    func trackCount() async throws -> Int {
        0
    }
}

private actor FactoryCache: CacheService {
    func initialize() async throws {}
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {}
    func invalidate(key _: String) async {}
    func clear() async {}
    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }
    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {}
    func invalidateAlbum(artist _: String, album _: String) async {}
    func invalidateAllAlbumYears() async {}
    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_: CachedAPIResult) async {}
    func invalidateCachedAPIResults(artist _: String, album _: String) async {}
    func syncToDisk() async throws {}
}

private func makeItem() -> FixPlanItem {
    FixPlanItem(
        id: UUID(),
        identity: FixPlanItemIdentity(
            readID: "MK-1",
            appleScriptID: "AS-1",
            artist: "Artist",
            album: "Album",
            trackName: "Track 1"
        ),
        changeType: .genreUpdate,
        oldValue: "Rock",
        newValue: "Metal",
        confidence: 90,
        source: "review-test"
    )
}

private func makePlan(_ item: FixPlanItem) -> FixPlan {
    let capturedAt = Date(timeIntervalSince1970: 100)
    return FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfigurationSnapshot.capture(options: UpdateOptions(), capturedAt: capturedAt),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "unit-test"
        ),
        items: [item]
    )
}
