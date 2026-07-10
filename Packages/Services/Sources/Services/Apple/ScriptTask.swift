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
        case read
        case mutation(ScriptTaskOutcome)
    }

    private let mode: Mode
    let deadline: ContinuousClock.Instant
    let dispatchError: @Sendable () -> any Error
    let timeoutError: @Sendable () -> any Error
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

    static func read(
        deadline: ContinuousClock.Instant,
        dispatchError: @escaping @Sendable () -> any Error,
        timeoutError: @escaping @Sendable () -> any Error,
        onDeadline: @escaping @Sendable (Duration) -> Void
    ) -> Self {
        Self(
            mode: .read,
            deadline: deadline,
            dispatchError: dispatchError,
            timeoutError: timeoutError,
            onDeadline: onDeadline
        )
    }

    static func mutation(
        deadline: ContinuousClock.Instant,
        dispatchError: @escaping @Sendable () -> any Error,
        timeoutError: @escaping @Sendable () -> any Error,
        outcome: ScriptTaskOutcome,
        onDeadline: @escaping @Sendable (Duration) -> Void
    ) -> Self {
        Self(
            mode: .mutation(outcome),
            deadline: deadline,
            dispatchError: dispatchError,
            timeoutError: timeoutError,
            onDeadline: onDeadline
        )
    }
}

enum ScriptTask {
    private static let overdueLogInterval: Duration = .seconds(60)

    static func run<Value: Sendable>(
        policy: ScriptTaskPolicy,
        onCompletion: @escaping @Sendable () -> Void,
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        // Reads may resolve early, but physical ownership ends only when the callback arrives.
        // Mutations ignore cancellation after dispatch and require a bounded outcome deadline.
        let relay = ScriptRelay<Value>(onCompletion: onCompletion)
        let dispatchResult: Result<Value, any Error> = .failure(policy.dispatchError())
        let timeoutResult: Result<Value, any Error> = .failure(policy.timeoutError())
        let outcomeResult: Result<Value, any Error>? = policy.outcome.map {
            .failure($0.error())
        }

        return try await withTaskCancellationHandler {
            guard relay.commitDispatch(deadline: policy.deadline, timeoutResult: dispatchResult) else {
                return try await relay.wait()
            }
            start { result in
                relay.complete(
                    result,
                    intent: policy.intent,
                    deadline: policy.deadline,
                    timeoutResult: timeoutResult
                )
            }
            startWatchdog(
                policy: policy,
                relay: relay,
                result: timeoutResult,
                outcomeResult: outcomeResult
            )
            return try await relay.wait()
        } onCancel: {
            relay.cancel(intent: policy.intent)
        }
    }

    private static func startWatchdog<Value: Sendable>(
        policy: ScriptTaskPolicy,
        relay: ScriptRelay<Value>,
        result: Result<Value, any Error>,
        outcomeResult: Result<Value, any Error>?
    ) {
        let watchdog = Task { [weak relay] in
            let clock = ContinuousClock()
            var nextLog = policy.deadline
            var isOutcomePending = policy.outcome != nil && outcomeResult != nil

            while true {
                let wakeAt = isOutcomePending
                    ? min(nextLog, policy.outcome?.deadline ?? nextLog)
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
                        relay.resolve(result)
                    }
                }

                if isOutcomePending,
                   let outcome = policy.outcome,
                   now >= outcome.deadline,
                   let outcomeResult {
                    relay.resolve(outcomeResult)
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
    private var onCompletion: (@Sendable () -> Void)?
    private var watchdog: Task<Void, Never>?
    private var state = State.ready

    init(onCompletion: @escaping @Sendable () -> Void) {
        self.onCompletion = onCompletion
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
        timeoutResult: Result<Value, any Error>
    ) -> Bool {
        lock.lock()
        guard case .ready = state else {
            lock.unlock()
            return false
        }
        guard ContinuousClock().now < deadline else {
            let completion = onCompletion
            onCompletion = nil
            let resolution = resolveLocked(timeoutResult)
            lock.unlock()
            completion?()
            resolution.continuation?.resume(with: resolution.result)
            return false
        }
        state = .dispatched
        lock.unlock()
        return true
    }

    func cancel(intent: ScriptIntent) {
        lock.lock()
        let completion: (@Sendable () -> Void)?
        switch state {
        case .dispatched where intent == .mutation:
            lock.unlock()
            return
        case .resolved:
            lock.unlock()
            return
        case .ready:
            completion = onCompletion
            onCompletion = nil
        case .dispatched:
            completion = nil
        }
        let resolution = resolveLocked(.failure(CancellationError()))
        lock.unlock()
        completion?()
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
        let shouldCancel = onCompletion == nil
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
            guard onCompletion != nil else { return false }
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
        let shouldNotify = if onCompletion == nil {
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
        intent: ScriptIntent,
        deadline: ContinuousClock.Instant,
        timeoutResult: Result<Value, any Error>
    ) {
        lock.lock()
        let completion = onCompletion
        onCompletion = nil
        let watchdog = watchdog
        self.watchdog = nil
        let isLate = intent == .read && ContinuousClock().now >= deadline
        let callbackResult = isLate ? timeoutResult : result
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
        completion?()
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
