@testable import Services

struct AcceptedApplyFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let cache: MockCacheService
    let snapshot: MockLibrarySnapshotService
    let trackStore: MockTrackStore
    let undo: UndoCoordinator
}

actor CheckpointProbe {
    private(set) var values: [WorkCheckpoint] = []
    private(set) var verifiedEffects: [CheckpointEffects] = []

    func append(_ checkpoint: WorkCheckpoint, effects: CheckpointEffects? = nil) {
        values.append(checkpoint)
        if let effects {
            verifiedEffects.append(effects)
        }
    }
}

struct CheckpointEffects: Sendable {
    let historyCount: Int
    let processingCount: Int
}
