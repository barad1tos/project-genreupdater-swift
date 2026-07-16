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
        persistRunRecord: { try await store.upsert($0) }
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
    try context.insert(PersistedRunRecord(
        runID: id,
        requestID: UUID(),
        triggerRaw: RunTrigger.manualCheck.rawValue,
        intentRaw: intentRaw,
        stateRaw: state.rawValue,
        scopeData: JSONEncoder().encode(scope),
        transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
        syncNewCount: nil,
        syncModifiedCount: nil,
        syncIdentityChangedCount: nil,
        syncRefreshedCount: nil,
        syncRemovedCount: nil,
        failureMessage: "Corrupted recovery record",
        startedAt: startedAt,
        finishedAt: nil
    ))
    try context.save()
}
