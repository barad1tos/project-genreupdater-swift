import Foundation
import Testing
@testable import Core
@testable import Services

private actor WriteHold {
    private var isEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

// Safety: the lock guards the callback installed by the dispatched test script.
private final class CallbackHold: @unchecked Sendable {
    typealias Callback = @Sendable (Result<String, any Error>) -> Void

    private let lock = NSLock()
    private var callback: Callback?

    func store(_ callback: @escaping Callback) {
        lock.withLock { self.callback = callback }
    }

    func finish(_ result: Result<String, any Error>) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(result)
    }
}

// Safety: all mutable state is protected by the lock.
private final class CallList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var values: [String] {
        lock.withLock { items }
    }
}

// Safety: the lock guards the one test result.
private final class ClearanceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func store(_ value: Bool) {
        lock.withLock { storedValue = value }
    }

    var value: Bool? {
        lock.withLock { storedValue }
    }
}

@Suite("Write admission")
struct WriteAdmissionTests {
    @Test("Batch and external writes share one reservation")
    func sharesWriteReservation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(fixedTier: .pro)
        )
        let batchHold = WriteHold()
        let calls = CallList()
        let batch = Task {
            try await processor.process(
                tracks: [admissionTrack("T1")],
                operation: { _ in
                    calls.append("batch")
                    await batchHold.wait()
                    return []
                },
                progressHandler: ignoreAdmissionProgress
            )
        }
        await batchHold.waitUntilEntered()

        await #expect(throws: BatchProcessorError.self) {
            _ = try await processor.performRecoverableWrite {
                calls.append("external-during-batch")
                return AppleScriptWriteResult.changed
            }
        }
        #expect(calls.values == ["batch"])
        await batchHold.release()
        _ = try await batch.value

        let externalHold = WriteHold()
        let external = Task {
            try await processor.performRecoverableWrite {
                calls.append("external")
                await externalHold.wait()
                return AppleScriptWriteResult.changed
            }
        }
        await externalHold.waitUntilEntered()

        await #expect(throws: BatchProcessorError.self) {
            _ = try await processor.process(
                tracks: [admissionTrack("T2")],
                operation: { _ in
                    calls.append("batch-during-external")
                    return []
                },
                progressHandler: ignoreAdmissionProgress
            )
        }
        #expect(calls.values == ["batch", "external"])
        await externalHold.release()
        _ = try await external.value
    }

    @Test("Recovery clearance waits for the physical callback")
    func clearanceWaitsForCallback() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(fixedTier: .pro)
        )
        let gate = ScriptGate(limit: 2)
        let callback = CallbackHold()
        let dispatches = CallList()
        let firstCall = ScriptCall(
            name: "update_property",
            intent: .mutation,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(20)),
            timeout: .milliseconds(20)
        )

        let outcome: AppleScriptOutcomeError
        do {
            _ = try await processor.performRecoverableWrite {
                try await ScriptDispatch.run(firstCall, limiter: nil, gate: gate) { finish in
                    dispatches.append("first")
                    callback.store(finish)
                }
            }
            Issue.record("Expected the first mutation outcome to remain unknown")
            return
        } catch let error as AppleScriptOutcomeError {
            outcome = error
        }
        let recoveryID = try #require(await processor.recoveryHoldID())
        let completion = try #require(outcome.completion)
        let firstClearance = Task {
            do {
                try await processor.clearRecovery(batchID: recoveryID)
                return true
            } catch {
                return false
            }
        }

        await waitForClearance(completion)
        #expect(completion.hasWaiters)
        let secondResult = ClearanceProbe()
        let secondClearance = Task {
            let didClear: Bool
            do {
                try await processor.clearRecovery(batchID: recoveryID)
                didClear = true
            } catch {
                didClear = false
            }
            secondResult.store(didClear)
            return didClear
        }

        await waitForResult(secondResult)
        #expect(secondResult.value == false)
        await #expect(throws: BatchProcessorError.self) {
            _ = try await processor.performRecoverableWrite {
                dispatches.append("early-second")
                return AppleScriptWriteResult.changed
            }
        }
        #expect(dispatches.values == ["first"])

        callback.finish(.success("done"))
        let clearanceResults = await [firstClearance.value, secondClearance.value]
        #expect(clearanceResults.count(where: { $0 }) == 1)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await processor.performRecoverableWrite {
                throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
            }
        }
        let newRecoveryID = try #require(await processor.recoveryHoldID())
        #expect(newRecoveryID != recoveryID)
        try await processor.clearRecovery(batchID: newRecoveryID)

        let secondCall = ScriptCall(
            name: "update_property",
            intent: .mutation,
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        _ = try await processor.performRecoverableWrite {
            try await ScriptDispatch.run(secondCall, limiter: nil, gate: gate) { finish in
                dispatches.append("second")
                finish(.success("done"))
            }
        }
        #expect(dispatches.values == ["first", "second"])
    }

    private func waitForClearance(_ completion: ScriptCompletion) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !completion.hasWaiters, ContinuousClock().now < deadline {
            await Task.yield()
        }
    }

    private func waitForResult(_ result: ClearanceProbe) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while result.value == nil, ContinuousClock().now < deadline {
            await Task.yield()
        }
    }
}

private func admissionTrack(_ id: String) -> Track {
    Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
}

private func ignoreAdmissionProgress(_: ProgressUpdate) {
    // Admission tests assert write ownership, not progress reporting.
}
