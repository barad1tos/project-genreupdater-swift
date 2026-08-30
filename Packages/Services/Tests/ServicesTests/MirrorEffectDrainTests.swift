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

    func openStore() throws -> TrackDataStore {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try TrackDataStore(modelContainer: ModelContainerFactory.create(
            schema: schema,
            configuration: configuration
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum EffectTargetFailure: Error {
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

private actor EffectCache: CacheService {
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

    func initialize() async throws {}
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {}
    func invalidate(key _: String) async throws {}
    func clear() async {}
    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }
    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {}

    func invalidateAlbum(artist: String, album: String) async throws {
        guard failingOperation != .albumYear else { throw EffectTargetFailure.requested }
        operations.append(.albumYear(artist: artist, album: album))
    }

    func invalidateAllAlbumYears() async {}
    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_: CachedAPIResult) async {}

    func invalidateCachedAPIResults(artist: String, album: String) async throws {
        guard failingOperation != .apiResults else { throw EffectTargetFailure.requested }
        operations.append(.apiResults(artist: artist, album: album))
    }

    func syncToDisk() async throws {}
}

private actor EffectSnapshot: LibrarySnapshotService {
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
    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {}
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }
}

private actor ProjectionRecorder: MirrorProjectionOutput {
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

private actor BlockingProjectionRecorder: MirrorProjectionOutput {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func refreshMirrorProjections() async throws {
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor EffectStore: TrackStateStore {
    private var pending: [PendingMirrorEffect]
    private var completionFailures: Int
    private var completedIDs: [UUID] = []
    private var fullListReads = 0
    private var nextReads = 0

    init(pending: [PendingMirrorEffect], completionFailures: Int = 0) {
        self.pending = pending
        self.completionFailures = completionFailures
    }

    func initialize() async throws {}
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
