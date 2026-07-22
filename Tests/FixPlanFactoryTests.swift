import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Fix plan write factory")
struct FixPlanFactoryTests {
    @Test("Fix plan writer enforces recovery admission")
    @MainActor
    func enforcesRecovery() async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: WriteAdmissionError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.fetchCalls.isEmpty)

        await fixture.script.returnUnknownOutcome()
        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.fetchCalls.map(\.batchSize) == [7])
        #expect(await fixture.script.fetchCalls.map(\.timeout) == [.seconds(45)])
        let recoveryID = try #require(await fixture.processor.recoveryHoldID())
        let fetchCount = await fixture.script.fetchCalls.count
        await #expect(throws: BatchProcessorError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.fetchCalls.count == fetchCount)
        try await fixture.processor.clearRecovery(batchID: recoveryID)
    }

    @Test("Fix plan writer rejects altered queued scope")
    @MainActor
    func rejectsAlteredScope() async {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = makeStaleInput(from: fixture)

        do {
            _ = try await fixture.run(input)
            Issue.record("Expected stale fix plan input")
        } catch let error as FixPlanWrite.Failure {
            guard case .staleInput = error else {
                Issue.record("Expected staleInput, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected FixPlanWrite.Failure, got \(error)")
        }
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.fetchCalls.isEmpty)
    }

    @Test("orchestrator closes work when the real writer rejects stale input")
    @MainActor
    func closesStaleWork() async {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = makeStaleInput(from: fixture)
        let capture = RunCapture()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await capture.append($0) },
            write: .init(writeFixPlan: fixture.write),
            now: { Date(timeIntervalSince1970: 120) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed run for stale write input")
            return
        }
        #expect(snapshot.finishedAt != nil)
        #expect(snapshot.workItems.allSatisfy { $0.state == .outcome(.failed) })
        #expect(await capture.last?.workItems.allSatisfy {
            $0.state == .outcome(.failed)
        } == true)
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.fetchCalls.isEmpty)
    }

    private func makeStaleInput(from fixture: WriteFixture) -> FixPlanWriteInput {
        let planScope = fixture.input.scope
        let alteredScope = ProcessingScopeSnapshot(
            id: planScope.id,
            createdAt: planScope.createdAt,
            source: .testArtists,
            normalizedTestArtists: ["Other Artist"],
            matchingRule: planScope.matchingRule,
            knownTrackCount: planScope.knownTrackCount,
            fingerprint: "altered-scope",
            reason: planScope.reason
        )
        return FixPlanWriteInput(
            target: fixture.input.target,
            scope: alteredScope,
            configuration: fixture.input.configuration,
            workItems: fixture.input.workItems
        )
    }
}

private struct WriteFixture {
    let input: FixPlanWriteInput
    let script: ScriptSpy
    let processor: BatchProcessor
    let runtime: RuntimeProbe
    let write: @Sendable (
        FixPlanWriteInput,
        @escaping WorkCheckpointSink
    ) async throws -> BatchUpdateResult
    let directory: URL

    func run(_ input: FixPlanWriteInput) async throws -> BatchUpdateResult {
        try await write(input) { _ in
            // Direct writer tests assert results; orchestrator tests own checkpoint assertions.
        }
    }
}

private actor RunCapture {
    private(set) var records: [RunRecord] = []

    var last: RunRecord? {
        records.last
    }

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

private actor RecoveryProbe {
    private var isHeld: Bool

    init(isHeld: Bool) {
        self.isHeld = isHeld
    }

    func check() -> Bool {
        defer { isHeld = false }
        return isHeld
    }
}

private actor RuntimeProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private actor ScriptSpy: AppleScriptClient {
    private var tracksByID: [String: Track] = [:]
    private(set) var fetchCalls: [(trackIDs: [String], batchSize: Int, timeout: Duration?)] = []
    private var shouldReturnUnknown = false

    func setTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func initialize() async throws {
        // This in-memory client requires no setup.
    }

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track] {
        fetchCalls.append((trackIDs, batchSize, timeout))
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

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
        // Factory tests only exercise single-track writes.
    }

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

    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {
        // The fixture is immutable after construction.
    }
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
    func initialize() async throws {
        // This in-memory store requires no setup.
    }
    func loadAllTracks() async throws -> [Track] {
        []
    }
    func saveTracks(_: [Track]) async throws {
        // Factory tests do not persist track state.
    }
    func deleteTrackIDs(_: [String]) async throws -> Int {
        0
    }
    func getTrack(byID _: String) async throws -> Track? {
        nil
    }
    func updateTrackProcessingState(id _: String, genreUpdated _: Bool?, yearUpdated _: Bool?) async throws {
        // Factory tests do not persist processing state.
    }
    func getUnprocessedTracks() async throws -> [Track] {
        []
    }
    func trackCount() async throws -> Int {
        0
    }
}

private actor FactoryCache: CacheService {
    func initialize() async throws {
        // This in-memory cache requires no setup.
    }
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {
        // Factory tests do not persist generic cache values.
    }
    func invalidate(key _: String) async {
        // Factory tests do not persist generic cache values.
    }
    func clear() async {
        // Factory tests do not persist generic cache values.
    }
    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }
    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {
        // Factory tests do not persist album-year cache values.
    }
    func invalidateAlbum(artist _: String, album _: String) async {
        // Factory tests do not persist album-year cache values.
    }
    func invalidateAllAlbumYears() async {
        // Factory tests do not persist album-year cache values.
    }
    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_: CachedAPIResult) async {
        // Factory tests do not persist API cache values.
    }
    func invalidateCachedAPIResults(artist _: String, album _: String) async {
        // Factory tests do not persist API cache values.
    }
    func syncToDisk() async throws {
        // This in-memory cache has no disk state.
    }
}

@MainActor
private func makeWriteFixture(hasInitialRecovery: Bool) async -> WriteFixture {
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
    let script = ScriptSpy()
    await script.setTracks([writeTrack()])
    let mapper = TrackIDMapper()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FixPlanFactoryTests-\(UUID().uuidString)")
    let processor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: directory),
        featureGate: FeatureGate(fixedTier: .pro)
    )
    let coordinator = makeCoordinator(script: script, mapper: mapper, directory: directory)
    let recovery = RecoveryProbe(isHeld: hasInitialRecovery)
    let runtime = RuntimeProbe()
    let write = FixPlanWrite.makeRunner(FixPlanWrite.RunnerDependencies(
        fixPlanStore: store,
        mapper: mapper,
        batchProcessor: processor,
        makeRuntime: { configuration, scope in
            #expect(configuration == plan.configuration)
            #expect(scope == plan.scope)
            await runtime.record()
            return FixPlanWrite.Runtime(coordinator: coordinator, scripts: script)
        },
        hasRunRecovery: { await recovery.check() }
    ))
    let input = makeWriteInput(plan: plan, decision: decision)
    return WriteFixture(
        input: input,
        script: script,
        processor: processor,
        runtime: runtime,
        write: write,
        directory: directory
    )
}

private func makeWriteInput(plan: FixPlan, decision: FixPlanReviewDecision) -> FixPlanWriteInput {
    FixPlanWriteInput(
        target: FixPlanWriteTarget(
            planID: plan.id,
            planRevision: plan.revision,
            decisionRevision: decision.revision
        ),
        scope: plan.scope,
        configuration: RunConfig(
            capturedAt: decision.decidedAt,
            writeAuthority: .reviewedPlan,
            automation: .manualOnly,
            scopeID: plan.scope.id,
            settings: plan.configuration,
            hadRecoveryHold: false
        ),
        workItems: plan.items.map(RunWorkItem.init(item:))
    )
}

private func makeCoordinator(
    script: ScriptSpy,
    mapper: TrackIDMapper,
    directory: URL
) -> UpdateCoordinator {
    let api = DashboardStateAPIService()
    return UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: APIOrchestrator(services: APIOrchestratorServices(
                musicBrainz: api,
                discogs: api,
                appleMusic: api
            )),
            scriptBridge: script,
            stores: .init(trackStore: FactoryTrackStore(), cache: FactoryCache()),
            undoCoordinator: UndoCoordinator(
                scriptBridge: script,
                directory: directory
            ),
            idMapper: mapper
        ),
        genreDeterminator: GenreDeterminator(),
        runtimeConfiguration: UpdateRuntimeConfiguration(areBatchUpdatesEnabled: false)
    )
}

private func writeTrack() -> Track {
    Track(
        id: "AS-1",
        name: "Track 1",
        artist: "Artist",
        album: "Album",
        genre: "Rock",
        appleScriptID: "AS-1"
    )
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
    var configuration = AppConfiguration()
    configuration.applescript.batchProcessing.idsBatchSize = 7
    configuration.applescript.timeouts.idsBatchFetch = .seconds(45)
    return FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: capturedAt
        ),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "unit-test"
        ),
        items: [item]
    )
}
