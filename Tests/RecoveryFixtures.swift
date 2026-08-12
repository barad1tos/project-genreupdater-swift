import Core
import Foundation
import Services
import SwiftData
@testable import Genre_Updater

struct RecoverySetup {
    let dependencies: AppDependencies
    let processor: BatchProcessor
    let store: any RunRecordStore
    let undo: UndoCoordinator
    let changeLog: RecoveryChangeLogStore
    let trackStore: TrackDataStore
    let persistenceContainer: ModelContainer
    let directory: URL
}

/// SwiftData-backed history store with a controllable save failure for
/// app-level recovery tests.
actor RecoveryChangeLogStore: ChangeLogStore {
    struct SaveFailure: Error {}
    struct ReadFailure: Error {}

    private let base: ChangeLogDataStore
    private var shouldFailSaves = false
    private var shouldFailReads = false

    init(base: ChangeLogDataStore) {
        self.base = base
    }

    func failSaves() {
        shouldFailSaves = true
    }

    func resumeSaves() {
        shouldFailSaves = false
    }

    func failReads() {
        shouldFailReads = true
    }

    func resumeReads() {
        shouldFailReads = false
    }

    func saveEntry(_ entry: ChangeLogEntry) async throws {
        guard !shouldFailSaves else { throw SaveFailure() }
        try await base.saveEntry(entry)
    }

    func saveEntries(_ entries: [ChangeLogEntry]) async throws {
        guard !shouldFailSaves else { throw SaveFailure() }
        try await base.saveEntries(entries)
    }

    func loadAll() async throws -> [ChangeLogEntry] {
        guard !shouldFailReads else { throw ReadFailure() }
        return try await base.loadAll()
    }

    func loadRecent(limit: Int) async throws -> [ChangeLogEntry] {
        guard !shouldFailReads else { throw ReadFailure() }
        return try await base.loadRecent(limit: limit)
    }

    func delete(entryID: UUID) async throws {
        try await base.delete(entryID: entryID)
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }
}

/// One write-uncertain track item for the recovery fixtures below.
private func uncertainWorkItem(
    state: WorkState,
    oldValue: String?,
    newValue: String?
) -> RunWorkItem {
    RunWorkItem(
        id: UUID(),
        target: .track(FixPlanItemIdentity(
            readID: "read-1",
            appleScriptID: "persistent-1",
            artist: "Artist",
            album: "Album",
            trackName: "Track"
        )),
        change: WorkChange(
            changeType: .genreUpdate,
            oldValue: oldValue,
            newValue: newValue,
            confidence: 90,
            source: "Library"
        ),
        state: state,
        detail: nil
    )
}

/// One write-uncertain run record bound to a recovery hold, plus its item.
func uncertainRunRecord(
    recoveryID: UUID?,
    itemState: WorkState = .attempted,
    oldValue: String? = "Rock",
    newValue: String? = "Stoner Rock"
) -> (record: RunRecord, item: RunWorkItem) {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: 1,
        createdAt: startedAt,
        reason: "recovery-test"
    )
    let item = uncertainWorkItem(state: itemState, oldValue: oldValue, newValue: newValue)
    let input = FixPlanWriteInput(
        target: FixPlanWriteTarget(
            planID: FixPlanID(),
            planRevision: .initial,
            decisionRevision: .initial
        ),
        scope: scope,
        configuration: RunConfig(
            capturedAt: startedAt,
            writeAuthority: .reviewedPlan,
            automation: .manualOnly,
            scopeID: scope.id,
            settings: FixPlanConfig.capture(
                configuration: AppConfiguration(),
                options: UpdateOptions(),
                capturedAt: startedAt
            ),
            hadRecoveryHold: false
        ),
        workItems: [item]
    )
    let lifecycle = RunLifecycleSnapshot(
        request: .manualWrite(input: input),
        scope: scope,
        startedAt: startedAt,
        phase: .suspended(.recoverable)
    )
    let record = RunRecord(
        lifecycle: lifecycle,
        transitions: [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .writing, timestamp: startedAt),
            RunLifecycleTransition(state: .recoverable, timestamp: startedAt),
        ],
        recoveryID: recoveryID,
        syncSummary: nil,
        failureMessage: "Unknown write outcome",
        finishedAt: nil
    )
    return (record, item)
}

/// Wraps a real store and fails the first N recovery reads, so tests can
/// drive the synthetic-hold path and then let the store recover.
actor FlakyRecoveryStore: RunRecordStore {
    struct StoreDown: Error {}

    private let base: any RunRecordStore
    private var failingReads: Int

    init(base: any RunRecordStore, failingReads: Int) {
        self.base = base
        self.failingReads = failingReads
    }

    func recoveryRecords() async throws -> RunReportPage {
        if failingReads > 0 {
            failingReads -= 1
            throw StoreDown()
        }
        return try await base.recoveryRecords()
    }

    func upsert(_ record: RunRecord) async throws {
        try await base.upsert(record)
    }

    func checkpoint(_ checkpoint: WorkCheckpoint, runID: RunID) async throws {
        try await base.checkpoint(checkpoint, runID: runID)
    }

    func loadAll() async throws -> [RunRecord] {
        try await base.loadAll()
    }

    func record(for runID: RunID) async throws -> RunRecord? {
        try await base.record(for: runID)
    }

    func prune(keepingLatest limit: Int) async throws -> Int {
        try await base.prune(keepingLatest: limit)
    }

    func claimRecovery(for runID: RunID, id: UUID, at timestamp: Date) async throws -> UUID? {
        try await base.claimRecovery(for: runID, id: id, at: timestamp)
    }

    func closeCorruptedRun(_ runID: RunID, at finishedAt: Date) async throws -> Bool {
        try await base.closeCorruptedRun(runID, at: finishedAt)
    }

    func closeReadOnlyCorruption(_ runID: RunID, at finishedAt: Date) async throws -> Bool {
        try await base.closeReadOnlyCorruption(runID, at: finishedAt)
    }

    func reports(matching query: RunReportQuery) async throws -> RunReportPage {
        try await base.reports(matching: query)
    }

    func reportItems(matching query: RunReportItemQuery) async throws -> RunReportItemPage {
        try await base.reportItems(matching: query)
    }

    func resolvedRecoveryRun(recoveryID: UUID) async throws -> RunID? {
        try await base.resolvedRecoveryRun(recoveryID: recoveryID)
    }

    func continuations(of runID: RunID) async throws -> [RunID] {
        try await base.continuations(of: runID)
    }

    func retainedPlanIDs() async throws -> Set<FixPlanID>? {
        try await base.retainedPlanIDs()
    }
}

/// Serves canned tracks for recovery observation in app-hosted tests.
actor RecoveryScriptStub: AppleScriptClient {
    private let tracks: [Track]

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func initialize() async throws {
        // The stub requires no setup.
    }

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(_ trackIDs: [String], batchSize _: Int, timeout _: Duration?) async throws -> [Track] {
        trackIDs.compactMap { id in tracks.first { ($0.appleScriptID ?? $0.id) == id } }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        tracks.map(\.id)
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws
        -> AppleScriptWriteResult {
        throw AppleScriptBridgeError.scriptNotFound(name: "update_property", searchPath: URL(filePath: "/dev/null"))
    }

    func batchUpdateTracks(_: [TrackPropertyUpdate]) async throws {
        // The stub never dispatches batch writes.
    }
}

@MainActor
func makeRecoverySetup(store: (any RunRecordStore)? = nil) async throws -> RecoverySetup {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Recovery-\(UUID().uuidString)")
    let processor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: directory),
        featureGate: FeatureGate(fixedTier: .pro)
    )
    let store = try store ?? RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())
    let persistenceContainer = try ModelContainerFactory.createInMemory()
    let changeLog = RecoveryChangeLogStore(
        base: ChangeLogDataStore(modelContainer: persistenceContainer)
    )
    let trackStore = TrackDataStore(modelContainer: persistenceContainer)
    let undo = UndoCoordinator(
        scriptBridge: RecoveryScriptStub(tracks: []),
        changeLogStore: changeLog,
        directory: directory.appendingPathComponent("undo", isDirectory: true)
    )
    let fixture = try makeFixture(testArtists: [], runRecordStore: store)
    fixture.dependencies.configureLibraryPersistenceForTesting(
        trackStore: trackStore,
        runRecordStore: store
    )
    fixture.dependencies.installTestWrites(TestWriteServices(
        batchProcessor: processor,
        undoCoordinator: undo,
        runRecordStore: store
    ))
    let orchestrator = RunOrchestrator(dependencies: .init(
        synchronizeLibrary: { SyncResult() },
        persistRunRecord: { try await store.upsert($0) },
        write: fixture.dependencies.writeDependencies(
            store: store,
            processor: processor,
            writeFixPlan: { _, _, _ in
                BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
            }
        )
    ))
    await fixture.dependencies.installTestOrchestrator(orchestrator)
    return RecoverySetup(
        dependencies: fixture.dependencies,
        processor: processor,
        store: store,
        undo: undo,
        changeLog: changeLog,
        trackStore: trackStore,
        persistenceContainer: persistenceContainer,
        directory: directory
    )
}

func insertCorruptedRun(
    id: UUID,
    state: RunLifecycleState,
    intentRaw: String = RunIntent.writeFixes.rawValue,
    transitionsData: Data = Data([0xDE, 0xAD, 0xBE, 0xEF]),
    into container: ModelContainer
) throws {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: 1,
        createdAt: startedAt,
        reason: "recovery-test"
    )
    let context = ModelContext(container)
    let record = try PersistedRunRecord(
        runID: id,
        intentRaw: intentRaw,
        stateRaw: state.rawValue,
        scopeData: JSONEncoder().encode(scope),
        transitionsData: transitionsData,
        startedAt: startedAt,
        finishedAt: nil
    )
    record.failureMessage = "Corrupted recovery record"
    context.insert(record)
    try context.save()
}
