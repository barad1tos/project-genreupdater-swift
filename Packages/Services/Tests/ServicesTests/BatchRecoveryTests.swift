import Foundation
import Testing
@testable import Core
@testable import Services

// Safety: all mutable state is protected by the lock.
private final class RecoveryList<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.withLock { items.append(item) }
    }

    var values: [T] {
        lock.withLock { items }
    }
}

@Suite("Batch recovery")
struct BatchRecoveryTests {
    @Test("Unknown write outcomes stop processing and save a checkpoint")
    func stopsOnUnknownOutcome() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)
        let processor = BatchProcessor(checkpointManager: checkpoint, featureGate: gate)
        let processedTrackIDs = RecoveryList<String>()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await processor.process(
                tracks: makeRecoveryTracks(count: 3),
                operation: { track in
                    processedTrackIDs.append(track.id)
                    if track.id == "T1" {
                        throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
                    }
                    return [ChangeLogEntry(changeType: .genreUpdate, trackID: track.id, artist: track.artist)]
                },
                progressHandler: { _ in }
            )
        }

        #expect(processedTrackIDs.values == ["T0", "T1"])
        #expect(await processor.state == .failed)
        let savedCheckpoint = try await checkpoint.loadLatest()
        #expect(savedCheckpoint?.processedTrackIDs == ["T0"])
        #expect(savedCheckpoint?.lastProcessedIndex == 0)

        let checkpointID = try #require(savedCheckpoint?.batchID)
        let restartedProcessor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: gate
        )
        let blockedTrackIDs = RecoveryList<String>()
        do {
            _ = try await restartedProcessor.process(
                tracks: makeRecoveryTracks(count: 3),
                operation: { track in
                    blockedTrackIDs.append(track.id)
                    return []
                },
                progressHandler: { _ in }
            )
            Issue.record("Expected the persisted recovery hold to block processing")
        } catch let error as BatchProcessorError {
            guard case let .recoveryRequired(recoveryID) = error else {
                Issue.record("Expected recoveryRequired, got \(error)")
                return
            }
            #expect(recoveryID == checkpointID)
        } catch {
            Issue.record("Expected recoveryRequired, got \(error)")
        }
        #expect(blockedTrackIDs.values.isEmpty)

        await #expect(throws: BatchProcessorError.self) {
            try await restartedProcessor.clearRecovery(batchID: UUID())
        }
        #expect(await restartedProcessor.recoveryHoldID() == checkpointID)

        try await restartedProcessor.clearRecovery(batchID: checkpointID)
        #expect(await restartedProcessor.recoveryHoldID() == nil)
        let restartedTrackIDs = RecoveryList<String>()
        _ = try await restartedProcessor.process(
            tracks: makeRecoveryTracks(count: 3),
            operation: { track in
                restartedTrackIDs.append(track.id)
                return []
            },
            progressHandler: { _ in }
        )
        #expect(restartedTrackIDs.values == ["T0", "T1", "T2"])
    }

    @Test("First unknown outcome keeps the first track resumable")
    func firstOutcomeKeepsTrack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)
        let processor = BatchProcessor(checkpointManager: checkpoint, featureGate: gate)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await processor.process(
                tracks: makeRecoveryTracks(count: 2),
                operation: { _ in
                    throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
                },
                progressHandler: { _ in }
            )
        }

        let savedCheckpoint = try #require(await checkpoint.loadLatest())
        #expect(savedCheckpoint.lastProcessedIndex == -1)
        try await processor.clearRecovery(batchID: savedCheckpoint.batchID)
        let restartedTrackIDs = RecoveryList<String>()
        _ = try await processor.process(
            tracks: makeRecoveryTracks(count: 2),
            operation: { track in
                restartedTrackIDs.append(track.id)
                return []
            },
            progressHandler: { _ in }
        )
        #expect(restartedTrackIDs.values == ["T0", "T1"])
    }

    @Test("Recovery survives checkpoint file write failure")
    func holdsAfterStorageFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "BatchRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gate = await FeatureGate(fixedTier: .pro)
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: root, recoverySuiteName: suiteName),
            featureGate: gate
        )

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await processor.process(
                tracks: makeRecoveryTracks(count: 1),
                operation: { _ in
                    let checkpointDirectory = root.appendingPathComponent("checkpoints")
                    try FileManager.default.removeItem(at: checkpointDirectory)
                    try Data("not-a-directory".utf8).write(to: checkpointDirectory)
                    throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
                },
                progressHandler: { _ in }
            )
        }

        let recoveryID = try #require(await processor.recoveryHoldID())
        let restarted = BatchProcessor(
            checkpointManager: CheckpointManager(directory: root, recoverySuiteName: suiteName),
            featureGate: gate
        )
        let writeCalls = RecoveryList<String>()
        await #expect(throws: BatchProcessorError.self) {
            _ = try await restarted.process(
                tracks: makeRecoveryTracks(count: 1),
                operation: { track in
                    writeCalls.append(track.id)
                    return []
                },
                progressHandler: { _ in }
            )
        }
        #expect(writeCalls.values.isEmpty)
        #expect(await restarted.recoveryHoldID() == recoveryID)

        try await restarted.clearRecovery(batchID: recoveryID)
    }
}

private func makeRecoveryTracks(count: Int) -> [Track] {
    (0 ..< count).map { index in
        Track(id: "T\(index)", name: "Track T\(index)", artist: "Artist", album: "Album")
    }
}
