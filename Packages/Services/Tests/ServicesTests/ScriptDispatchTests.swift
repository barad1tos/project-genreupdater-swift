import Foundation
import Testing
@testable import Services

@Suite("Script dispatch ownership", .serialized)
struct ScriptDispatchTests {
    @Test("Rate wait consumes the caller deadline")
    func boundsRateWait() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(10))
        _ = await limiter.acquire()
        let dispatches = DispatchCount()
        let call = ScriptCall(
            name: "fetch_tracks",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
            timeout: .milliseconds(100)
        )

        await #expect(throws: AppleScriptBridgeError.self) {
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

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await ScriptDispatch.run(call, limiter: limiter, gate: gate) { _ in } as String?
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
        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await firstTask.value
        }

        let blockedCall = ScriptCall(
            name: "fetch_tracks_by_ids",
            intent: .read,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
            timeout: .milliseconds(100)
        )
        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await ScriptDispatch.run(blockedCall, limiter: nil, gate: gate) { finish in
                finish(.success("unexpected"))
            }
        }

        callback.resolve(.success("late"))
        let finalCall = ScriptCall(
            name: "fetch_tracks_by_ids",
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
