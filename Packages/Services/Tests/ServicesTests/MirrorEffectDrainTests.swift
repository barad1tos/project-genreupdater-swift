import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Mirror effect drain")
struct MirrorEffectDrainTests {
    @Test(
        "Each later target failure remains durable across relaunch",
        arguments: [EffectFailureStage.apiResults, .snapshot, .projections]
    )
    func targetFailureSurvivesRelaunch(stage: EffectFailureStage) async throws {
        let fixture = try PersistentEffectFixture()
        defer { fixture.remove() }
        let identity = AlbumIdentity(artist: "Artist", album: "Album")
        let expectedPendingCount: Int

        do {
            let store = try fixture.openStore()
            let initial = try await store.loadMirrorSnapshot()
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: initial.revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve,
                effects: [
                    .invalidateAlbumYear(identity),
                    .invalidateAPIResults(identity),
                    .invalidateSnapshot,
                    .refreshProjections,
                ]
            ))
            let cacheFailure: EffectCache.FailingOperation? = stage == .apiResults ? .apiResults : nil
            let drain = MirrorEffectDrain(
                store: store,
                cache: EffectCache(failingOperation: cacheFailure),
                snapshot: EffectSnapshot(shouldFail: stage == .snapshot),
                projections: ProjectionRecorder(shouldFail: stage == .projections)
            )

            await drain.drain()
            expectedPendingCount = switch stage {
            case .apiResults: 3
            case .snapshot: 2
            case .projections: 1
            }
            #expect(try await store.pendingMirrorEffects().count == expectedPendingCount)
        }

        do {
            let store = try fixture.openStore()
            let drain = MirrorEffectDrain(
                store: store,
                cache: EffectCache(),
                snapshot: EffectSnapshot(),
                projections: ProjectionRecorder()
            )
            await drain.drain()
            #expect(try await store.pendingMirrorEffects().isEmpty)
        }
    }

    @Test("Pending invalidations survive a target failure and persistent relaunch")
    func pendingEffectsSurviveRelaunch() async throws {
        let fixture = try PersistentEffectFixture()
        defer { fixture.remove() }
        let identity = AlbumIdentity(artist: "  In Flames ", album: " Battles  ")

        let pendingIDs: [UUID]
        do {
            let store = try fixture.openStore()
            let snapshot = try await store.loadMirrorSnapshot()
            let result = try await store.commitMirror(MirrorCommit(
                baseRevision: snapshot.revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve,
                effects: [
                    .invalidateAlbumYear(identity),
                    .invalidateAPIResults(identity),
                    .invalidateSnapshot,
                    .refreshProjections,
                ]
            ))
            pendingIDs = result.pendingEffectIDs
            #expect(pendingIDs.count == 4)

            let cache = EffectCache(failingOperation: .albumYear)
            let drain = MirrorEffectDrain(
                store: store,
                cache: cache,
                snapshot: EffectSnapshot(),
                projections: ProjectionRecorder()
            )
            await drain.drain()
            #expect(try await store.pendingMirrorEffects().map(\.id) == pendingIDs)
        }

        do {
            let store = try fixture.openStore()
            let cache = EffectCache()
            let snapshot = EffectSnapshot()
            let projections = ProjectionRecorder()
            let drain = MirrorEffectDrain(
                store: store,
                cache: cache,
                snapshot: snapshot,
                projections: projections
            )

            await drain.drain()

            #expect(await cache.operations == [
                .albumYear(artist: "In Flames", album: "Battles"),
                .apiResults(artist: "In Flames", album: "Battles"),
            ])
            #expect(await snapshot.clearCount == 1)
            #expect(await projections.refreshCount == 1)
            #expect(try await store.pendingMirrorEffects().isEmpty)
        }
    }

    @Test("Pending effects retain stable revision and sequence order")
    func pendingEffectsHaveStableOrder() async throws {
        let store = try TrackDataStore.createInMemory()
        try await store.initialize()
        let initial = try await store.loadMirrorSnapshot()
        let first = try await store.commitMirror(MirrorCommit(
            baseRevision: initial.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.invalidateSnapshot, .refreshProjections]
        ))
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: first.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.invalidateAPIResults(AlbumIdentity(artist: "Artist", album: "Album"))]
        ))

        let pending = try await store.pendingMirrorEffects()
        let next = try await store.nextPendingMirrorEffect()

        #expect(next == pending.first)
        #expect(try pending.map(\.revision) == [first.revision, first.revision, first.revision.advanced()])
        #expect(pending.map(\.sequence) == [0, 1, 0])
        #expect(pending.map(\.effect) == [
            .invalidateSnapshot,
            .refreshProjections,
            .invalidateAPIResults(AlbumIdentity(artist: "Artist", album: "Album")),
        ])
    }

    @Test(
        "A completion failure replays every idempotent target after the drain is recreated",
        arguments: EffectReplayTarget.allCases
    )
    func completionFailureReplaysTarget(target: EffectReplayTarget) async throws {
        let effect = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 4),
            sequence: 0,
            effect: target.effect
        )
        let store = EffectStore(pending: [effect], completionFailures: 1)
        let cache = EffectCache()
        let snapshot = EffectSnapshot()
        let projections = ProjectionRecorder()
        let firstDrain = MirrorEffectDrain(
            store: store,
            cache: cache,
            snapshot: snapshot,
            projections: projections
        )

        await firstDrain.drain()
        let relaunchedDrain = MirrorEffectDrain(
            store: store,
            cache: cache,
            snapshot: snapshot,
            projections: projections
        )
        await relaunchedDrain.drain()

        await target.expectReplay(cache: cache, snapshot: snapshot, projections: projections)
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }

    @Test("A post-commit drain delivers older backlog before the newly committed effects")
    func committedIDsPreserveBacklog() async throws {
        let older = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 3),
            sequence: 0,
            effect: .invalidateSnapshot
        )
        let committed = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 4),
            sequence: 0,
            effect: .refreshProjections
        )
        let store = EffectStore(pending: [older, committed])
        let snapshot = EffectSnapshot()
        let projections = ProjectionRecorder()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: snapshot,
            projections: projections
        )

        await drain.drain(newlyCommittedEffectIDs: [committed.id])

        #expect(await snapshot.clearCount == 1)
        #expect(await projections.refreshCount == 1)
        #expect(await store.completedEffectIDs() == [older.id, committed.id])
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }

    @Test("Drain fetches only the next pending effect")
    func drainUsesSingleEffectReads() async {
        let effects = [
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 3),
                sequence: 0,
                effect: .invalidateSnapshot
            ),
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 3),
                sequence: 1,
                effect: .refreshProjections
            ),
        ]
        let store = EffectStore(pending: effects)
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: EffectSnapshot(),
            projections: ProjectionRecorder()
        )

        await drain.drain()

        let reads = await store.readCounts()
        #expect(reads.fullList == 0)
        #expect(reads.next == effects.count + 1)
    }

    @Test("Cancellation after target execution leaves the current effect pending")
    func cancellationDoesNotCompleteCurrentEffect() async throws {
        let effect = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 9),
            sequence: 0,
            effect: .refreshProjections
        )
        let store = EffectStore(pending: [effect])
        let projections = BlockingProjectionRecorder()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: EffectSnapshot(),
            projections: projections
        )
        let task = Task { await drain.drain() }
        await projections.waitUntilStarted()

        task.cancel()
        await projections.resume()

        await task.value
        #expect(try await store.pendingMirrorEffects().map(\.id) == [effect.id])
    }

    @Test("Concurrent drain requests execute each effect once")
    func concurrentDrainRequestsAreSingleFlight() async throws {
        let effect = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 10),
            sequence: 0,
            effect: .refreshProjections
        )
        let store = EffectStore(pending: [effect])
        let projections = SingleFlightProjectionRecorder()
        let reporter = EffectReporter()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: EffectSnapshot(),
            projections: projections,
            reporter: reporter
        )
        let first = Task { await drain.drain() }
        await projections.waitUntilStarted()
        let second = Task { await drain.drain() }
        await drain.waitForQueuedRequest()

        await projections.resume()
        await first.value
        await second.value

        #expect(await projections.refreshCount == 1)
        #expect(try await store.pendingMirrorEffects().isEmpty)
        #expect(await reporter.failures.isEmpty)
    }

    @Test("A waiting drain takes over when the active caller is cancelled")
    func cancelledLeaderHandsOff() async throws {
        let effect = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 11),
            sequence: 0,
            effect: .refreshProjections
        )
        let store = EffectStore(pending: [effect])
        let projections = SingleFlightProjectionRecorder()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: EffectSnapshot(),
            projections: projections
        )
        let first = Task { await drain.drain() }
        await projections.waitUntilStarted()
        let second = Task { await drain.drain() }
        await drain.waitForQueuedRequest()

        first.cancel()
        await projections.resume()
        await first.value
        await second.value

        #expect(await projections.refreshCount == 2)
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }

    @Test("A queued drain retries a temporary failure and clears its report")
    func queuedRetryClearsFailure() async throws {
        let effect = PendingMirrorEffect(
            id: UUID(),
            revision: MirrorRevision(value: 12),
            sequence: 0,
            effect: .refreshProjections
        )
        let store = EffectStore(pending: [effect])
        let projections = RetryProjectionRecorder()
        let reporter = EffectReporter()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: EffectSnapshot(),
            projections: projections,
            reporter: reporter
        )
        let first = Task { await drain.drain() }
        await projections.waitUntilStarted()
        let second = Task { await drain.drain() }
        await drain.waitForQueuedRequest()

        await projections.resume()
        await first.value
        await second.value

        #expect(await projections.refreshCount == 2)
        #expect(try await store.pendingMirrorEffects().isEmpty)
        #expect(await reporter.events == [.failure(.temporary), .clear])
    }

    @Test("Malformed album effects reject the whole mirror commit")
    func malformedEffectRollsBack() async throws {
        let store = try TrackDataStore.createInMemory()
        try await store.initialize()
        let initial = try await store.loadMirrorSnapshot()
        let malformed = AlbumIdentity(artist: "", album: "Album")
        let track = Track(
            id: "new-track",
            name: "New Track",
            artist: "Artist",
            album: "Album",
            appleScriptID: "new-track"
        )

        await #expect(throws: MirrorEffectPersistenceError.self) {
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: initial.revision,
                inventoryChange: replacementInventory(for: [track]),
                repairs: [],
                upserts: [track],
                certificates: .invalidate(.membershipChanged),
                effects: [.invalidateAlbumYear(malformed)]
            ))
        }

        let afterFailure = try await store.loadMirrorSnapshot()
        #expect(afterFailure.revision == initial.revision)
        #expect(afterFailure.presentIDs.isEmpty)
        #expect(try await store.getTrack(byID: track.id) == nil)
        #expect(try await store.pendingMirrorEffects().isEmpty)

        let valid = try await store.commitMirror(MirrorCommit(
            baseRevision: afterFailure.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.invalidateSnapshot]
        ))
        let expectedRevision = try initial.revision.advanced()
        #expect(valid.revision == expectedRevision)
    }

    @Test("Completed effect records stay bounded")
    func completedEffectRecordsStayBounded() async throws {
        let fixture = try PersistentEffectFixture()
        defer { fixture.remove() }

        do {
            let store = try fixture.openStore()
            let initial = try await store.loadMirrorSnapshot()
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: initial.revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve,
                effects: [.invalidateSnapshot, .refreshProjections, .invalidateSnapshot]
            ))
            let drain = MirrorEffectDrain(
                store: store,
                cache: EffectCache(),
                snapshot: EffectSnapshot(),
                projections: ProjectionRecorder()
            )
            await drain.drain()
        }

        let container = try fixture.openContainer()
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PersistedMirrorEffect>())
        #expect(records.count == 1)
        #expect(records.first?.completedAt != nil)
        #expect(try await TrackDataStore(modelContainer: container).pendingMirrorEffects().isEmpty)
    }

    @Test("Corrupted durable effects are reported as repair-required")
    func corruptedEffectHasPermanentFailureKind() async {
        let store = EffectStore(
            pending: [],
            readFailure: MirrorEffectPersistenceError.invalidKind("unknown")
        )
        let reporter = EffectReporter()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(),
            snapshot: EffectSnapshot(),
            projections: ProjectionRecorder(),
            reporter: reporter
        )

        await drain.drain()

        #expect(await reporter.failures.map(\.kind) == [.corruptedQueue])
    }
}

private struct PersistentEffectFixture {
    let directory: URL
    let storeURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "MirrorEffects-\(UUID().uuidString)", directoryHint: .isDirectory)
        storeURL = directory.appending(path: "GenreUpdater.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func openContainer() throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(
            schema: schema,
            configuration: configuration
        )
    }

    func openStore() throws -> TrackDataStore {
        try TrackDataStore(modelContainer: openContainer())
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum EffectTargetFailure: Error {
    case requested
}

enum EffectReplayTarget: CaseIterable, Sendable {
    case albumYear
    case apiResults
    case snapshot
    case projections

    var effect: MirrorEffect {
        let identity = AlbumIdentity(artist: "In Flames", album: "Battles")
        switch self {
        case .albumYear:
            return .invalidateAlbumYear(identity)
        case .apiResults:
            return .invalidateAPIResults(identity)
        case .snapshot:
            return .invalidateSnapshot
        case .projections:
            return .refreshProjections
        }
    }

    fileprivate func expectReplay(
        cache: EffectCache,
        snapshot: EffectSnapshot,
        projections: ProjectionRecorder
    ) async {
        switch self {
        case .albumYear:
            #expect(await cache.operations == [
                .albumYear(artist: "In Flames", album: "Battles"),
                .albumYear(artist: "In Flames", album: "Battles"),
            ])
        case .apiResults:
            #expect(await cache.operations == [
                .apiResults(artist: "In Flames", album: "Battles"),
                .apiResults(artist: "In Flames", album: "Battles"),
            ])
        case .snapshot:
            #expect(await snapshot.clearCount == 2)
        case .projections:
            #expect(await projections.refreshCount == 2)
        }
    }
}

enum EffectFailureStage: Sendable {
    case apiResults
    case snapshot
    case projections
}

actor EffectCache: CacheService {
    enum FailingOperation {
        case albumYear
        case apiResults
    }

    enum Operation: Equatable {
        case albumYear(artist: String, album: String)
        case apiResults(artist: String, album: String)
    }

    private(set) var operations: [Operation] = []
    private let failingOperation: FailingOperation?

    init(failingOperation: FailingOperation? = nil) {
        self.failingOperation = failingOperation
    }

    func initialize() async throws {
        // Intentionally empty: this cache double has no startup work.
    }
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {
        // Intentionally empty: generic cache writes are outside effect-drain tests.
    }
    func invalidate(key _: String) async throws {
        // Intentionally empty: keyed invalidation is outside effect-drain tests.
    }
    func clear() async {
        // Intentionally empty: whole-cache clearing is outside effect-drain tests.
    }
    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }
    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {
        // Intentionally empty: the double records invalidations, not cache writes.
    }

    func invalidateAlbum(artist: String, album: String) async throws {
        guard failingOperation != .albumYear else { throw EffectTargetFailure.requested }
        operations.append(.albumYear(artist: artist, album: album))
    }

    func invalidateAllAlbumYears() async {
        // Intentionally empty: durable effects invalidate one album at a time.
    }
    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_: CachedAPIResult) async {
        // Intentionally empty: the double records invalidations, not API writes.
    }

    func invalidateCachedAPIResults(artist: String, album: String) async throws {
        guard failingOperation != .apiResults else { throw EffectTargetFailure.requested }
        operations.append(.apiResults(artist: artist, album: album))
    }

    func syncToDisk() async throws {
        // Intentionally empty: this in-memory double has nothing to persist.
    }
}

actor EffectSnapshot: LibrarySnapshotService {
    private(set) var clearCount = 0
    private let shouldFail: Bool
    var isEnabled: Bool {
        true
    }

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func loadSnapshot() async throws -> [Track]? {
        nil
    }
    func saveSnapshot(_: [Track]) async throws -> String {
        "snapshot"
    }
    func clearSnapshot() async throws {
        guard !shouldFail else { throw EffectTargetFailure.requested }
        clearCount += 1
    }
    func isSnapshotValid() async -> Bool {
        false
    }
    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        nil
    }
    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {
        // Intentionally empty: effect delivery only clears the snapshot.
    }
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }
}

actor ProjectionRecorder: MirrorProjectionOutput {
    private(set) var refreshCount = 0
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func refreshMirrorProjections() async throws {
        guard !shouldFail else { throw EffectTargetFailure.requested }
        refreshCount += 1
    }
}

private actor EffectReporter: MirrorEffectDrainReporting {
    enum Event: Equatable {
        case failure(MirrorEffectDrainFailure.Kind)
        case clear
    }

    private(set) var failures: [MirrorEffectDrainFailure] = []
    private(set) var events: [Event] = []

    func reportMirrorEffectFailure(_ failure: MirrorEffectDrainFailure) {
        failures.append(failure)
        events.append(.failure(failure.kind))
    }

    func clearMirrorEffectFailure() {
        events.append(.clear)
    }
}

actor EffectStore: TrackStateStore {
    private var pending: [PendingMirrorEffect]
    private var completionFailures: Int
    private var completedIDs: [UUID] = []
    private var fullListReads = 0
    private var nextReads = 0
    private let readFailure: MirrorEffectPersistenceError?

    init(
        pending: [PendingMirrorEffect],
        completionFailures: Int = 0,
        readFailure: MirrorEffectPersistenceError? = nil
    ) {
        self.pending = pending
        self.completionFailures = completionFailures
        self.readFailure = readFailure
    }

    func initialize() async throws {
        // Intentionally empty: this in-memory store is ready immediately.
    }
    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try emptyMirrorSnapshot()
    }
    func commitMirror(_: MirrorCommit) async throws -> MirrorCommitResult {
        try MirrorCommitResult(revision: .initial, snapshot: emptyMirrorSnapshot())
    }
    func getTrack(byID _: String) async throws -> Track? {
        nil
    }
    func getHistoricalTrack(byID _: String) async throws -> Track? {
        nil
    }
    func commitAppliedChange(_: ChangeLogEntry) async throws -> MirrorRevision {
        .initial
    }
    func commitObservedChange(_: ChangeLogEntry) async throws -> MirrorRevision {
        .initial
    }
    func commitRevertedChange(_: ChangeLogEntry, removingHistoryEntryID _: UUID) async throws -> MirrorRevision {
        .initial
    }
    func getUnprocessedTracks() async throws -> [Track] {
        []
    }
    func trackCount() async throws -> Int {
        0
    }
    func pendingMirrorEffects() async throws -> [PendingMirrorEffect] {
        fullListReads += 1
        return pending
    }

    func nextPendingMirrorEffect() async throws -> PendingMirrorEffect? {
        nextReads += 1
        if let readFailure {
            throw readFailure
        }
        return pending.first
    }

    func completeMirrorEffect(id: UUID) async throws {
        guard completionFailures == 0 else {
            completionFailures -= 1
            throw EffectTargetFailure.requested
        }
        pending.removeAll { $0.id == id }
        completedIDs.append(id)
    }

    func completedEffectIDs() -> [UUID] {
        completedIDs
    }

    func readCounts() -> (fullList: Int, next: Int) {
        (fullListReads, nextReads)
    }

    private func emptyMirrorSnapshot() throws -> TrackMirrorSnapshot {
        try TrackMirrorSnapshot(
            revision: .initial,
            membershipStamp: MembershipFingerprint.make(ids: []),
            presentIDs: [],
            memberIdentities: [:],
            presentTracks: [],
            repairCandidates: [],
            certificates: []
        )
    }
}
