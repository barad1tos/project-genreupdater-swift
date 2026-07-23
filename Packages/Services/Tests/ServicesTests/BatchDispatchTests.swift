import Core
import Foundation
import Testing
@testable import Services

@Suite("Batch dispatch safety")
struct BatchDispatchTests {
    @Test("Pre-dispatch batch failure reaches the caller")
    func keepsDeadline() async throws {
        let fixture = try makeBatchBridge()
        let bridge = fixture.bridge
        let scriptsDirectory = fixture.directory
        defer { try? FileManager.default.removeItem(at: scriptsDirectory) }
        let attempts = BatchAttemptCounter()
        let checkpoints = BatchAttemptCounter()

        do {
            try await bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ], onAttempt: {
                _ = await checkpoints.next()
            }, execute: { _ in
                _ = await attempts.next()
                throw AppleScriptBridgeError.dispatchDeadline(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            })
            Issue.record("Expected dispatchDeadline")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 1)
        #expect(await checkpoints.value == 0)
    }

    @Test("Pre-dispatch setup failure does not record an attempt")
    func setupErrorUnattempted() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkpoints = BatchAttemptCounter()

        await #expect(throws: BatchSetupError.self) {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ], onAttempt: {
                _ = await checkpoints.next()
            }, execute: { _ in
                throw BatchSetupError()
            })
        }
        #expect(await checkpoints.value == 0)
    }

    @Test("Pre-dispatch batch cancellation does not record an attempt")
    func cancellationUnattempted() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkpoints = BatchAttemptCounter()

        await #expect(throws: CancellationError.self) {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ], onAttempt: {
                _ = await checkpoints.next()
            }, execute: { _ in
                throw CancellationError()
            })
        }
        #expect(await checkpoints.value == 0)
    }

    @Test("Unknown batch outcome reaches the caller")
    func preservesUnknownOutcome() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkpoints = BatchAttemptCounter()

        await #expect(throws: AppleScriptOutcomeError.self) {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ], onAttempt: {
                _ = await checkpoints.next()
            }, execute: { _ in
                throw AppleScriptOutcomeError(scriptName: "batch_update_tracks", duration: .seconds(3))
            })
        }
        #expect(await checkpoints.value == 1)
    }

    @Test("unknown batch outcome preserves a typed checkpoint store failure")
    func storeFailureKeepsOutcome() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let request = RunRequest.manualWrite(input: input)
        let durable = RunLifecycleSnapshot(
            request: request,
            scope: input.scope,
            startedAt: Date(timeIntervalSince1970: 100),
            phase: .active(.writing)
        )
        let checkpoint = WorkCheckpoint.beforeAttempt([itemID])
        let candidate = try durable.applying(checkpoint)
        let stored = CheckpointStoreFailure(
            checkpoint: checkpoint,
            candidate: candidate,
            durableSnapshot: durable,
            isWriteAdjacent: true,
            reason: "checkpoint store unavailable"
        )

        do {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ], onAttempt: {
                throw WorkCheckpointError.store(stored)
            }, execute: { _ in
                throw AppleScriptOutcomeError(
                    scriptName: "batch_update_tracks",
                    reason: "connection ended before reply"
                )
            })
            Issue.record("Expected typed checkpoint store failure")
        } catch let WorkCheckpointError.store(failure) {
            #expect(failure.checkpoint == checkpoint)
            #expect(failure.candidate == candidate)
            #expect(failure.durableSnapshot == durable)
            #expect(failure.isWriteAdjacent)
            #expect(failure.reason.contains("checkpoint store unavailable"))
            #expect(failure.reason.contains("connection ended before reply"))
            #expect(failure.reason.contains("outcome is unknown"))
        } catch {
            Issue.record("Expected typed checkpoint store failure, got \(error)")
        }
    }

    private func makeBridge(scriptsDirectory: URL = FileManager.default.temporaryDirectory) -> AppleScriptBridge {
        let installer = ScriptInstaller(
            scriptsDirectory: scriptsDirectory,
            bundleScriptsDirectory: nil
        )
        return AppleScriptBridge(installer: installer)
    }

    private func makeBatchBridge() throws -> (bridge: AppleScriptBridge, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("batch_update_tracks.scpt"))
        return (makeBridge(scriptsDirectory: directory), directory)
    }
}

private struct BatchSetupError: Error {}

private actor BatchAttemptCounter {
    private var count = 0

    var value: Int {
        count
    }

    func next() -> Int {
        count += 1
        return count
    }
}
