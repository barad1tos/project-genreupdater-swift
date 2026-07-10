import Foundation

enum ScriptIntent: Equatable {
    case read
    case mutation
}

struct ScriptTaskOutcome {
    let deadline: ContinuousClock.Instant
    let error: @Sendable () -> any Error
}

struct ScriptTaskPolicy {
    private enum Mode {
        case read(@Sendable () -> any Error)
        case mutation(ScriptTaskOutcome)
    }

    private let mode: Mode
    let deadline: ContinuousClock.Instant
    let dispatchError: @Sendable () -> any Error
    let onDeadline: @Sendable (Duration) -> Void

    var intent: ScriptIntent {
        switch mode {
        case .read:
            .read
        case .mutation:
            .mutation
        }
    }

    var outcome: ScriptTaskOutcome? {
        guard case let .mutation(outcome) = mode else { return nil }
        return outcome
    }

    var resolutionDeadline: ContinuousClock.Instant {
        outcome?.deadline ?? deadline
    }

    var resolutionError: @Sendable () -> any Error {
        switch mode {
        case let .read(error):
            error
        case let .mutation(outcome):
            outcome.error
        }
    }

    static func read(
        deadline: ContinuousClock.Instant,
        dispatchError: @escaping @Sendable () -> any Error,
        timeoutError: @escaping @Sendable () -> any Error,
        onDeadline: @escaping @Sendable (Duration) -> Void
    ) -> Self {
        Self(
            mode: .read(timeoutError),
            deadline: deadline,
            dispatchError: dispatchError,
            onDeadline: onDeadline
        )
    }

    static func mutation(
        deadline: ContinuousClock.Instant,
        dispatchError: @escaping @Sendable () -> any Error,
        outcome: ScriptTaskOutcome,
        onDeadline: @escaping @Sendable (Duration) -> Void
    ) -> Self {
        Self(
            mode: .mutation(outcome),
            deadline: deadline,
            dispatchError: dispatchError,
            onDeadline: onDeadline
        )
    }
}

enum ScriptTask {
    private static let overdueLogInterval: Duration = .seconds(60)

    static func run<Value: Sendable>(
        policy: ScriptTaskPolicy,
        onOwnershipReleased: @escaping @Sendable () -> Void,
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        // Reads may resolve early, but physical ownership ends only when the callback arrives.
        // Mutations ignore cancellation after dispatch. Results after the outcome deadline become
        // unknown-outcome errors, so callers must reverify before retrying a write.
        let relay = ScriptRelay<Value>(onOwnershipReleased: onOwnershipReleased)
        let dispatchResult: Result<Value, any Error> = .failure(policy.dispatchError())
        let deadlineResult: Result<Value, any Error> = .failure(policy.resolutionError())

        return try await withTaskCancellationHandler {
            guard relay.commitDispatch(deadline: policy.deadline, dispatchFailureResult: dispatchResult) else {
                return try await relay.wait()
            }
            start { result in
                relay.complete(
                    result,
                    deadline: policy.resolutionDeadline,
                    deadlineResult: deadlineResult
                )
            }
            startWatchdog(
                policy: policy,
                relay: relay,
                deadlineResult: deadlineResult
            )
            return try await relay.wait()
        } onCancel: {
            relay.cancel(intent: policy.intent)
        }
    }

    private static func startWatchdog<Value: Sendable>(
        policy: ScriptTaskPolicy,
        relay: ScriptRelay<Value>,
        deadlineResult: Result<Value, any Error>
    ) {
        let watchdog = Task { [weak relay] in
            let clock = ContinuousClock()
            var nextLog = policy.deadline
            var isOutcomePending = policy.intent == .mutation

            while true {
                let wakeAt = isOutcomePending
                    ? min(nextLog, policy.resolutionDeadline)
                    : nextLog
                do {
                    try await clock.sleep(until: wakeAt)
                } catch {
                    return
                }
                guard let relay, relay.isCallbackPending else { return }
                let now = clock.now

                if now >= nextLog {
                    let overdue = policy.deadline.duration(to: now)
                    guard relay.notifyDeadline(overdue, action: policy.onDeadline) else { return }
                    nextLog = now.advanced(by: overdueLogInterval)
                    if policy.intent == .read {
                        relay.resolve(deadlineResult)
                    }
                }

                if isOutcomePending, now >= policy.resolutionDeadline {
                    relay.resolve(deadlineResult)
                    isOutcomePending = false
                }
            }
        }
        relay.installWatchdog(watchdog)
    }
}

// Safety: every mutable field is accessed while `lock` is held.
private final class ScriptRelay<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case ready
        case dispatched
        case resolved
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var onOwnershipReleased: (@Sendable () -> Void)?
    private var watchdog: Task<Void, Never>?
    private var state = State.ready

    init(onOwnershipReleased: @escaping @Sendable () -> Void) {
        self.onOwnershipReleased = onOwnershipReleased
    }

    deinit {
        watchdog?.cancel()
    }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func commitDispatch(
        deadline: ContinuousClock.Instant,
        dispatchFailureResult: Result<Value, any Error>
    ) -> Bool {
        lock.lock()
        guard case .ready = state else {
            lock.unlock()
            return false
        }
        guard ContinuousClock().now < deadline else {
            let ownershipRelease = onOwnershipReleased
            onOwnershipReleased = nil
            let resolution = resolveLocked(dispatchFailureResult)
            lock.unlock()
            ownershipRelease?()
            resolution.continuation?.resume(with: resolution.result)
            return false
        }
        state = .dispatched
        lock.unlock()
        return true
    }

    func cancel(intent: ScriptIntent) {
        lock.lock()
        let ownershipRelease: (@Sendable () -> Void)?
        switch state {
        case .dispatched where intent == .mutation:
            lock.unlock()
            return
        case .resolved:
            lock.unlock()
            return
        case .ready:
            ownershipRelease = onOwnershipReleased
            onOwnershipReleased = nil
        case .dispatched:
            ownershipRelease = nil
        }
        let resolution = resolveLocked(.failure(CancellationError()))
        lock.unlock()
        ownershipRelease?()
        resolution.continuation?.resume(with: resolution.result)
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        switch state {
        case .resolved:
            lock.unlock()
        case .ready, .dispatched:
            let resolution = resolveLocked(result)
            lock.unlock()
            resolution.continuation?.resume(with: resolution.result)
        }
    }

    func installWatchdog(_ watchdog: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = onOwnershipReleased == nil
        if !shouldCancel {
            self.watchdog = watchdog
        }
        lock.unlock()
        if shouldCancel {
            watchdog.cancel()
        }
    }

    var isCallbackPending: Bool {
        lock.withLock {
            guard onOwnershipReleased != nil else { return false }
            switch state {
            case .ready:
                return false
            case .dispatched, .resolved:
                return true
            }
        }
    }

    func notifyDeadline(
        _ overdue: Duration,
        action: @Sendable (Duration) -> Void
    ) -> Bool {
        lock.lock()
        let shouldNotify = if onOwnershipReleased == nil {
            false
        } else {
            switch state {
            case .ready:
                false
            case .dispatched, .resolved:
                true
            }
        }
        lock.unlock()
        if shouldNotify {
            action(overdue)
        }
        return shouldNotify
    }

    func complete(
        _ result: Result<Value, any Error>,
        deadline: ContinuousClock.Instant,
        deadlineResult: Result<Value, any Error>
    ) {
        lock.lock()
        let ownershipRelease = onOwnershipReleased
        onOwnershipReleased = nil
        let watchdog = watchdog
        self.watchdog = nil
        let isLate = ContinuousClock().now >= deadline
        let callbackResult = isLate ? deadlineResult : result
        let resolution: (
            continuation: CheckedContinuation<Value, any Error>?,
            result: Result<Value, any Error>
        )? = if case .resolved = state {
            nil
        } else {
            resolveLocked(callbackResult)
        }
        lock.unlock()

        watchdog?.cancel()
        ownershipRelease?()
        if let resolution {
            resolution.continuation?.resume(with: resolution.result)
        }
    }

    private func resolveLocked(
        _ result: Result<Value, any Error>
    ) -> (continuation: CheckedContinuation<Value, any Error>?, result: Result<Value, any Error>) {
        state = .resolved
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        return (continuation, result)
    }
}
