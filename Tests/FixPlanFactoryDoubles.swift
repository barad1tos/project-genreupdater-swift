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

actor ScriptSpy: MusicAppMutating, MusicAppVerifying {
    private var tracksByID: [String: Track] = [:]
    private(set) var metadataFetches: [[MusicDatabaseTrackID]] = []
    private var shouldReturnUnknown = false
    private var shouldReturnChanged = false

    func setTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track] {
        metadataFetches.append(databaseIDs)
        return databaseIDs.compactMap { tracksByID[$0.rawValue] }
    }

    func update(
        _: MusicTrackUpdate,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        try await onAttempt()
        if shouldReturnUnknown {
            throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        }
        return shouldReturnChanged ? .changed : .noChange
    }

    func update(
        _: [MusicTrackUpdate],
        onAttempt _: @escaping WriteAttemptHook
    ) async throws {
        // Factory tests only exercise single-track writes.
    }

    func returnUnknownOutcome() {
        shouldReturnUnknown = true
    }

    func returnChangedOutcome() {
        shouldReturnChanged = true
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

    func deletePlans(notIn _: Set<FixPlanID>) async throws -> Int {
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

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        TrackMirrorSnapshot(revision: .initial, tracks: [], coverage: .unknown)
    }

    @discardableResult
    func applyMirror(_ update: TrackMirrorUpdate) async throws -> MirrorRevision {
        // Factory tests do not persist track state.
        update.baseRevision.advanced()
    }

    func getTrack(byID _: String) async throws -> Track? {
        nil
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // Factory tests do not persist applied track changes.
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
