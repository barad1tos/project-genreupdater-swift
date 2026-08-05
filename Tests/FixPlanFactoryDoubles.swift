import Core
import Foundation
import Services

actor RunCapture {
    private(set) var records: [RunRecord] = []

    var last: RunRecord? {
        records.last
    }

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

actor RecoveryProbe {
    private var isHeld: Bool

    init(isHeld: Bool) {
        self.isHeld = isHeld
    }

    func check() -> Bool {
        defer { isHeld = false }
        return isHeld
    }
}

actor RuntimeProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

actor ScriptSpy: AppleScriptClient {
    private var tracksByID: [String: Track] = [:]
    private(set) var fetchCalls: [ScriptFetchCall] = []
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
        fetchCalls.append(ScriptFetchCall(trackIDs: trackIDs, batchSize: batchSize, timeout: timeout))
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

    func batchUpdateTracks(_: [TrackPropertyUpdate]) async throws {
        // Factory tests only exercise single-track writes.
    }

    func returnUnknownOutcome() {
        shouldReturnUnknown = true
    }
}

actor FactoryPlanStore: FixPlanStore {
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

    func deletePlans(notIn _: Set<UUID>) async throws -> Int {
        0
    }
}

actor FactoryTrackStore: TrackStateStore {
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

actor FactoryCache: CacheService {
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
