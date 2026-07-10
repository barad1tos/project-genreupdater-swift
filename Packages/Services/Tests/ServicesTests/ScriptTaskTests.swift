import Foundation
import Testing
@testable import Services

@Suite("Script task deadlines", .serialized)
struct ScriptTaskTests {
    @Test("Pre-cancelled read skips dispatch and releases ownership")
    func preCancelledRead() async {
        let dispatches = TaskProbe()
        let completions = TaskProbe()
        let task: Task<String, any Error> = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let policy = ScriptTaskPolicy.read(
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                dispatchError: { TaskTimeoutError() },
                timeoutError: { TaskTimeoutError() },
                onDeadline: { _ in }
            )
            return try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {
                    Task { await completions.record() }
                },
                start: { _ in
                    Task { await dispatches.record() }
                }
            )
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await dispatches.executions == 0)
        #expect(await completions.waitForExecutions(1))
    }

    @Test("Expired dispatch skips callback and releases ownership")
    func rejectsExpiredDispatch() async {
        let dispatches = TaskProbe()
        let completions = TaskProbe()
        let policy = ScriptTaskPolicy.read(
            deadline: ContinuousClock().now,
            dispatchError: { TaskDispatchError() },
            timeoutError: { TaskTimeoutError() },
            onDeadline: { _ in }
        )

        await #expect(throws: TaskDispatchError.self) {
            _ = try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {
                    Task { await completions.record() }
                },
                start: { (_: @Sendable (Result<String, any Error>) -> Void) in
                    Task { await dispatches.record() }
                }
            )
        }
        #expect(await dispatches.executions == 0)
        #expect(await completions.waitForExecutions(1))
    }

    @Test("Read timeout returns before its physical callback")
    func returnsReadTimeout() async {
        let callback = TaskLatch()
        let completion = TaskLatch()
        let task = Task {
            let policy = ScriptTaskPolicy.read(
                deadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
                dispatchError: { TaskTimeoutError() },
                timeoutError: { TaskTimeoutError() },
                onDeadline: { _ in }
            )
            _ = try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {
                    Task { await completion.block() }
                },
                start: { finish in
                    Task {
                        await callback.block()
                        finish(.success("late"))
                    }
                }
            )
        }
        #expect(await callback.waitForEntry())

        await #expect(throws: TaskTimeoutError.self) {
            _ = try await task.value
        }
        let didComplete = await completion.waitForEntry(timeout: .milliseconds(50))
        #expect(!didComplete)

        await callback.release()
        #expect(await completion.waitForEntry())
        await completion.release()
    }

    @Test("Read cancellation retains physical ownership")
    func cancelsRead() async {
        let callback = TaskLatch()
        let completion = TaskLatch()
        let task = Task {
            let policy = ScriptTaskPolicy.read(
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                dispatchError: { TaskTimeoutError() },
                timeoutError: { TaskTimeoutError() },
                onDeadline: { _ in }
            )
            _ = try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {
                    Task { await completion.block() }
                },
                start: { finish in
                    Task {
                        await callback.block()
                        finish(.success("late"))
                    }
                }
            )
        }
        #expect(await callback.waitForEntry())

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let didComplete = await completion.waitForEntry(timeout: .milliseconds(50))
        #expect(!didComplete)

        await callback.release()
        #expect(await completion.waitForEntry())
        await completion.release()
    }

    @Test("Mutation waits for its physical callback past deadline")
    func waitsForMutation() async throws {
        let callback = TaskLatch()
        let returned = TaskProbe()
        let task = Task {
            let policy = ScriptTaskPolicy.mutation(
                deadline: ContinuousClock().now.advanced(by: .milliseconds(50)),
                dispatchError: { TaskTimeoutError() },
                outcome: ScriptTaskOutcome(
                    deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                    error: { TaskOutcomeError() }
                ),
                onDeadline: { _ in }
            )
            let value = try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {},
                start: { finish in
                    Task {
                        await callback.block()
                        finish(.success("applied"))
                    }
                }
            )
            await returned.record()
            return value
        }
        #expect(await callback.waitForEntry())
        try await Task.sleep(for: .milliseconds(100))
        #expect(await returned.executions == 0)

        await callback.release()
        #expect(try await task.value == "applied")
        #expect(await returned.executions == 1)
    }

    @Test("Mutation cancellation waits for its physical result")
    func cancelsMutation() async throws {
        let callback = TaskLatch()
        let returned = TaskProbe()
        let task = Task {
            let policy = ScriptTaskPolicy.mutation(
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                dispatchError: { TaskTimeoutError() },
                outcome: ScriptTaskOutcome(
                    deadline: ContinuousClock().now.advanced(by: .seconds(2)),
                    error: { TaskOutcomeError() }
                ),
                onDeadline: { _ in }
            )
            let value = try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {},
                start: { finish in
                    Task {
                        await callback.block()
                        finish(.success("applied"))
                    }
                }
            )
            await returned.record()
            return value
        }
        #expect(await callback.waitForEntry())

        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await returned.executions == 0)

        await callback.release()
        #expect(try await task.value == "applied")
        #expect(await returned.executions == 1)
    }

    @Test("Mutation outcome ceiling returns while retaining physical ownership")
    func boundsUnknownOutcome() async {
        let callback = TaskLatch()
        let completion = TaskLatch()
        let clock = ContinuousClock()
        let task = Task {
            let policy = ScriptTaskPolicy.mutation(
                deadline: clock.now.advanced(by: .milliseconds(50)),
                dispatchError: { TaskTimeoutError() },
                outcome: ScriptTaskOutcome(
                    deadline: clock.now.advanced(by: .milliseconds(150)),
                    error: { TaskOutcomeError() }
                ),
                onDeadline: { _ in }
            )
            _ = try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: {
                    Task { await completion.block() }
                },
                start: { finish in
                    Task {
                        await callback.block()
                        finish(.success("late"))
                    }
                }
            )
        }
        #expect(await callback.waitForEntry())

        await #expect(throws: TaskOutcomeError.self) {
            _ = try await task.value
        }
        let didComplete = await completion.waitForEntry(timeout: .milliseconds(50))
        #expect(!didComplete)

        await callback.release()
        #expect(await completion.waitForEntry())
        await completion.release()
    }

    @Test("Mutation callback after outcome deadline returns outcome error")
    func rejectsLateMutationCallback() async {
        let callback = TaskLatch()
        let watchdog = TaskGate()
        let releases = OwnershipCounter()
        defer { watchdog.release() }

        let task = Task {
            let clock = ContinuousClock()
            let policy = ScriptTaskPolicy.mutation(
                deadline: clock.now.advanced(by: .milliseconds(50)),
                dispatchError: { TaskTimeoutError() },
                outcome: ScriptTaskOutcome(
                    deadline: clock.now.advanced(by: .milliseconds(150)),
                    error: { TaskOutcomeError() }
                ),
                onDeadline: { _ in
                    // Freeze before the outcome check so the late callback must resolve through complete().
                    watchdog.block()
                }
            )
            return try await ScriptTask.run(
                policy: policy,
                onOwnershipReleased: { releases.record() },
                start: { finish in
                    Task {
                        await callback.block()
                        finish(.success("late"))
                    }
                }
            )
        }
        #expect(await callback.waitForEntry())
        #expect(await watchdog.waitForEntry())

        try? await Task.sleep(for: .milliseconds(150))
        await callback.release()

        await #expect(throws: TaskOutcomeError.self) {
            _ = try await task.value
        }
        #expect(releases.count == 1)
    }

    @Test("Synchronous callback is delivered")
    func deliversSynchronousCallback() async throws {
        let completions = TaskProbe()
        let policy = ScriptTaskPolicy.read(
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            dispatchError: { TaskTimeoutError() },
            timeoutError: { TaskTimeoutError() },
            onDeadline: { _ in }
        )

        let value = try await ScriptTask.run(
            policy: policy,
            onOwnershipReleased: {
                Task { await completions.record() }
            },
            start: { finish in
                finish(.success("ready"))
            }
        )

        #expect(value == "ready")
        #expect(await completions.waitForExecutions(1))
    }
}

private struct TaskDispatchError: Error {}
private struct TaskTimeoutError: Error {}
private struct TaskOutcomeError: Error {}

private actor TaskProbe {
    private(set) var executions = 0

    func record() {
        executions += 1
    }

    func waitForExecutions(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while executions != count, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        return executions == count
    }
}

private actor TaskLatch {
    private var isEntered = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        isEntered = true
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForEntry(timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isEntered, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        return isEntered
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

// Safety: the lock protects the counter and every access to it.
private final class OwnershipCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}

// Safety: the condition protects both flags and every access to them.
private final class TaskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isEntered = false
    private var isReleased = false

    func block() {
        condition.lock()
        isEntered = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitForEntry(timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if hasEntered {
                return true
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return false
    }

    private var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isEntered
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
