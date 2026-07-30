import Core
import Foundation
import Services
import SwiftData
@testable import Genre_Updater

struct RecoverySetup {
    let dependencies: AppDependencies
    let processor: BatchProcessor
    let store: any RunRecordStore
    let directory: URL
}

/// One write-uncertain run record bound to a recovery hold, plus its item.
func uncertainRunRecord(
    recoveryID: UUID,
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
    let item = RunWorkItem(
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
        state: itemState,
        detail: nil
    )
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
func makeRecoverySetup(store: (any RunRecordStore)? = nil) throws -> RecoverySetup {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Recovery-\(UUID().uuidString)")
    let processor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: directory),
        featureGate: FeatureGate(fixedTier: .pro)
    )
    let store = try store ?? RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())
    let fixture = try makeFixture(testArtists: [], runRecordStore: store)
    fixture.dependencies.installTestWrites(TestWriteServices(
        batchProcessor: processor,
        runRecordStore: store
    ))
    let orchestrator = RunOrchestrator(dependencies: .init(
        synchronizeLibrary: { SyncResult() },
        persistRunRecord: { try await store.upsert($0) },
        write: fixture.dependencies.writeDependencies(
            store: store,
            processor: processor,
            writeFixPlan: { _, _ in
                BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
            }
        )
    ))
    fixture.dependencies.installTestOrchestrator(orchestrator)
    return RecoverySetup(
        dependencies: fixture.dependencies,
        processor: processor,
        store: store,
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
