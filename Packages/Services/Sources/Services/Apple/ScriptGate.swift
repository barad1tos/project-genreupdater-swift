import Foundation

actor ScriptGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let deadlineTask: Task<Void, Never>
    }

    #if DEBUG
    struct TestHooks {
        let afterGrant: (@Sendable () async -> Void)?

        init(afterGrant: (@Sendable () async -> Void)? = nil) {
            self.afterGrant = afterGrant
        }
    }
    #endif

    private var limit: Int
    private var activePermits = 0
    private var waiters: [Waiter] = []
    #if DEBUG
    private let hooks: TestHooks?
    #endif

    var queuedCount: Int {
        waiters.count
    }

    init(limit: Int) {
        self.limit = max(1, limit)
        #if DEBUG
        hooks = nil
        #endif
    }

    #if DEBUG
    init(limit: Int, hooks: TestHooks) {
        self.limit = max(1, limit)
        self.hooks = hooks
    }
    #endif

    func updateLimit(_ limit: Int) {
        self.limit = max(1, limit)
        resumeWaiters()
    }

    func acquire(
        scriptName: String,
        deadline: ContinuousClock.Instant,
        timeout: Duration
    ) async throws -> ScriptPermit {
        try Task.checkCancellation()
        try checkDeadline(scriptName: scriptName, deadline: deadline, timeout: timeout)
        if activePermits < limit {
            activePermits += 1
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    enqueue(
                        id: id,
                        scriptName: scriptName,
                        deadline: deadline,
                        timeout: timeout,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        #if DEBUG
        await hooks?.afterGrant?()
        #endif
        do {
            try Task.checkCancellation()
            try checkDeadline(scriptName: scriptName, deadline: deadline, timeout: timeout)
        } catch {
            release()
            throw error
        }
        return ScriptPermit {
            Task { await self.release() }
        }
    }

    private func release() {
        guard activePermits > 0 else {
            assertionFailure("Script permit count underflow")
            return
        }
        activePermits -= 1
        resumeWaiters()
    }

    private func resumeWaiters() {
        while activePermits < limit, !waiters.isEmpty {
            activePermits += 1
            let waiter = waiters.removeFirst()
            waiter.deadlineTask.cancel()
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func enqueue(
        id: UUID,
        scriptName: String,
        deadline: ContinuousClock.Instant,
        timeout: Duration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        let deadlineTask = Task { [self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                return
            }
            expire(id, scriptName: scriptName, timeout: timeout)
        }
        waiters.append(Waiter(
            id: id,
            continuation: continuation,
            deadlineTask: deadlineTask
        ))
    }

    private func expire(_ id: UUID, scriptName: String, timeout: Duration) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(
            throwing: AppleScriptBridgeError.dispatchDeadline(
                scriptName: scriptName,
                duration: timeout
            )
        )
    }

    private func checkDeadline(
        scriptName: String,
        deadline: ContinuousClock.Instant,
        timeout: Duration
    ) throws {
        guard ContinuousClock().now < deadline else {
            throw AppleScriptBridgeError.dispatchDeadline(
                scriptName: scriptName,
                duration: timeout
            )
        }
    }
}

// Safety: `lock` guards the one-shot release closure.
final class ScriptPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        releaseAction = release
    }

    func release() {
        let action = lock.withLock {
            let action = releaseAction
            releaseAction = nil
            return action
        }
        action?()
    }

    deinit {
        release()
    }
}
