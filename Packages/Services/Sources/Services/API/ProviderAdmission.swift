import Foundation

struct ProviderCallTimeout: Error {}

actor ProviderAdmission {
    #if DEBUG
    typealias TestHooks = (
        didEnqueue: (@Sendable () -> Void)?,
        afterGrant: (@Sendable () async -> Void)?
    )
    #endif

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var activeCalls = 0
    private var waiters: [Waiter] = []
    #if DEBUG
    private let hooks: TestHooks?
    #endif

    #if DEBUG
    init(limit: Int, hooks: TestHooks? = nil) {
        self.limit = max(1, limit)
        self.hooks = hooks
    }
    #else
    init(limit: Int) {
        self.limit = max(1, limit)
    }
    #endif

    func execute<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let operationTask: Task<Value, any Error> = Task {
            try await acquire()
            do {
                let value = try await operation()
                release()
                return value
            } catch {
                release()
                throw error
            }
        }
        return try await ProviderCallRace.value(
            of: operationTask,
            timeout: timeout
        )
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCalls < limit {
            activeCalls += 1
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: continuation))
                    #if DEBUG
                    hooks?.didEnqueue?()
                    #endif
                    if Task.isCancelled {
                        cancel(id)
                    }
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
        } catch {
            release()
            throw error
        }
    }

    private func release() {
        guard activeCalls > 0 else {
            assertionFailure("Provider admission count underflow")
            return
        }
        activeCalls -= 1
        resumeWaiters()
    }

    private func resumeWaiters() {
        while activeCalls < limit, !waiters.isEmpty {
            activeCalls += 1
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

// Safety: the lock serializes the one-shot continuation and timeout state.
private final class ProviderCallRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    static func value(
        of operationTask: Task<Value, any Error>,
        timeout: Duration
    ) async throws -> Value {
        let race = ProviderCallRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.installContinuation(continuation)
                Task {
                    await race.resolve(operationTask.result)
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    race.resolve(
                        .failure(ProviderCallTimeout()),
                        cancelling: operationTask
                    )
                }
                race.installTimeout(timeoutTask)
            }
        } onCancel: {
            race.resolve(
                .failure(CancellationError()),
                cancelling: operationTask
            )
        }
    }

    private func installContinuation(
        _ continuation: CheckedContinuation<Value, any Error>
    ) {
        let pendingResult = lock.withLock { () -> Result<Value, any Error>? in
            guard !isResolved else {
                let result = self.pendingResult
                self.pendingResult = nil
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    private func installTimeout(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !isResolved else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func resolve(
        _ result: Result<Value, any Error>,
        cancelling operationTask: Task<Value, any Error>? = nil
    ) {
        let resolution = lock.withLock {
            guard !isResolved else { return nil as (CheckedContinuation<Value, any Error>?, Task<Void, Never>?)? }
            isResolved = true
            pendingResult = continuation == nil ? result : nil
            let resolution = (continuation, timeoutTask)
            continuation = nil
            timeoutTask = nil
            return resolution
        }
        guard let resolution else { return }

        operationTask?.cancel()
        resolution.1?.cancel()
        resolution.0?.resume(with: result)
    }
}
