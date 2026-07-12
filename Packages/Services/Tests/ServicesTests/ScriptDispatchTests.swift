import Foundation
import Testing
@testable import Services

@Suite("Script dispatch ownership", .serialized)
struct ScriptDispatchTests {
    @Test("Rate wait consumes the caller deadline")
    func boundsRateWait() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(10))
        _ = await limiter.acquire()
        let dispatches = DispatchCount()
        let call = ScriptCall(
            name: "fetch_tracks",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
            timeout: .milliseconds(100)
        )

        await expectBridgeFailure(.dispatchDeadline) {
            _ = try await ScriptDispatch.run(
                call,
                limiter: limiter,
                gate: ScriptGate(limit: 1)
            ) { _ in
                dispatches.record()
            } as String?
        }
        #expect(dispatches.value == 0)
    }

    @Test("Gate rejection returns an unused rate token")
    func returnsUnusedToken() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(10))
        let gate = ScriptGate(limit: 1)
        let heldPermit = try await gate.acquire(
            scriptName: "held",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        defer { heldPermit.release() }
        let call = ScriptCall(
            name: "fetch_tracks",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
            timeout: .milliseconds(100)
        )

        await expectBridgeFailure(.dispatchDeadline) {
            _ = try await ScriptDispatch.run(call, limiter: limiter, gate: gate) { _ in
                // Gate rejection must prevent the physical dispatch callback from being installed.
            } as String?
        }

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 1)
    }

    @Test("Read timeout retains its permit until callback")
    func retainsPermit() async throws {
        let gate = ScriptGate(limit: 1)
        let callback = DispatchCallback<String?>()
        let firstCall = ScriptCall(
            name: "fetch_tracks",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(250)),
            timeout: .milliseconds(250)
        )
        let firstTask = Task {
            try await ScriptDispatch.run(firstCall, limiter: nil, gate: gate) { finish in
                callback.store(finish)
            }
        }
        #expect(await callback.waitUntilStored())
        await expectBridgeFailure(.timeout) {
            _ = try await firstTask.value
        }

        let blockedCall = ScriptCall(
            name: "lookup_tracks",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
            timeout: .milliseconds(100)
        )
        await expectBridgeFailure(.dispatchDeadline) {
            _ = try await ScriptDispatch.run(blockedCall, limiter: nil, gate: gate) { finish in
                finish(.success("unexpected"))
            }
        }

        callback.resolve(.success("late"))
        let finalCall = ScriptCall(
            name: "lookup_tracks",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let result: String? = try await ScriptDispatch.run(finalCall, limiter: nil, gate: gate) { finish in
            finish(.success("ready"))
        }
        #expect(result == "ready")
    }

    @Test("Dispatched mutation ignores caller cancellation")
    func preservesMutationOutcome() async throws {
        let callback = DispatchCallback<String?>()
        let call = ScriptCall(
            name: "update_property",
            intent: .mutation,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(250)),
            timeout: .milliseconds(250)
        )
        let task = Task {
            try await ScriptDispatch.run(call, limiter: nil, gate: ScriptGate(limit: 1)) { finish in
                callback.store(finish)
            }
        }
        #expect(await callback.waitUntilStored())

        task.cancel()
        try await Task.sleep(for: .milliseconds(300))
        callback.resolve(.success("applied"))

        #expect(try await task.value == "applied")
    }

    @Test("Mutation outcome ceiling retains its permit until callback")
    func boundsMutationOutcome() async throws {
        let gate = ScriptGate(limit: 1)
        let callback = DispatchCallback<String?>()
        let timeout: Duration = .milliseconds(100)
        let call = ScriptCall(
            name: "update_property",
            intent: .mutation,
            deadline: ContinuousClock().now.advanced(by: timeout),
            timeout: timeout
        )
        let task = Task {
            try await ScriptDispatch.run(call, limiter: nil, gate: gate) { finish in
                callback.store(finish)
            }
        }
        #expect(await callback.waitUntilStored())

        do {
            _ = try await task.value
            Issue.record("Expected unknown mutation outcome")
        } catch let error as AppleScriptOutcomeError {
            #expect(error.duration == timeout * 3)
        } catch {
            Issue.record("Expected AppleScriptOutcomeError, got \(error)")
        }

        await expectBridgeFailure(.dispatchDeadline) {
            let permit = try await gate.acquire(
                scriptName: "blocked",
                deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
                timeout: .milliseconds(100)
            )
            permit.release()
        }

        callback.resolve(.success("late"))
        let permit = try await gate.acquire(
            scriptName: "released",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        permit.release()
    }
}

private enum BridgeFailure {
    case dispatchDeadline
    case timeout

    func matches(_ error: AppleScriptBridgeError) -> Bool {
        switch (self, error) {
        case (.dispatchDeadline, .dispatchDeadline), (.timeout, .timeout):
            true
        default:
            false
        }
    }
}

private func expectBridgeFailure(
    _ expected: BridgeFailure,
    operation: () async throws -> Void
) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as AppleScriptBridgeError {
        #expect(expected.matches(error), "Expected \(expected), got \(error)")
    } catch {
        Issue.record("Expected AppleScriptBridgeError, got \(error)")
    }
}

// Safety: the lock protects the callback and every access to it.
private final class DispatchCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Value, any Error>) -> Void)?

    func store(_ callback: @escaping @Sendable (Result<Value, any Error>) -> Void) {
        lock.withLock { self.callback = callback }
    }

    func waitUntilStored(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if lock.withLock({ callback != nil }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.withLock { callback }?(result)
    }
}

// Safety: the lock protects the count and every access to it.
private final class DispatchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func record() {
        lock.withLock { count += 1 }
    }
}
