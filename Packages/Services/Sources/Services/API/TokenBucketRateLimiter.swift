import Core
import OSLog

enum RateLimitError: Error {
    case deadlineExceeded
}

/// Token-bucket rate limiter for throttling API requests.
///
/// Each instance is configured with a maximum token count and a refill interval.
/// Tokens are consumed by `acquire()` and refilled one-per-interval automatically.
/// Typical configurations:
/// - MusicBrainz: `maxTokens: 1, refillInterval: .seconds(1)` (1 req/sec)
/// - Discogs: `maxTokens: 60, refillInterval: .seconds(60)` (60 req/min)
public actor TokenBucketRateLimiter: RateLimiter {
    private enum WaitResult {
        case granted(Duration)
        case cancelled
        case deadlineExceeded
    }

    private enum WaiterState: Equatable {
        case registered
        case queued
        case cancelledBeforeEnqueue
    }

    private struct Waiter {
        let id: UUID
        let queuedAt: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant?
        let continuation: CheckedContinuation<WaitResult, Never>
    }

    #if DEBUG
    struct TestHooks {
        let beforeEnqueue: (@Sendable () async -> Void)?
        let afterCancel: (@Sendable () async -> Void)?
        let afterGrant: (@Sendable () async -> Void)?

        init(
            beforeEnqueue: (@Sendable () async -> Void)? = nil,
            afterCancel: (@Sendable () async -> Void)? = nil,
            afterGrant: (@Sendable () async -> Void)? = nil
        ) {
            self.beforeEnqueue = beforeEnqueue
            self.afterCancel = afterCancel
            self.afterGrant = afterGrant
        }
    }
    #endif

    // MARK: - Properties

    private let maxTokens: Int
    private let refillInterval: Duration
    private let clock: ContinuousClock
    #if DEBUG
    private let hooks: TestHooks?
    #endif

    private var currentTokens: Int
    private var lastRefillInstant: ContinuousClock.Instant
    private var totalRequests: Int = 0
    private var totalWaitTime: Duration = .zero
    private var waiters: [Waiter] = []
    private var waiterStates: [UUID: WaiterState] = [:]
    private var deadlineWaiterCount = 0
    private var wakeTask: Task<Void, Never>?
    private var wakeID: UUID?
    private let log = Logger(subsystem: "com.genreupdater", category: "RateLimiter")

    // MARK: - Initialization

    /// Creates a token-bucket rate limiter.
    ///
    /// - Parameters:
    ///   - maxTokens: Maximum burst capacity. Nonpositive values normalize to one token.
    ///   - refillInterval: Time between refills. Nonpositive values normalize to one nanosecond.
    ///   - clock: Clock used for timing. Defaults to `ContinuousClock()`.
    public init(
        maxTokens: Int,
        refillInterval: Duration,
        clock: ContinuousClock = ContinuousClock()
    ) {
        let settings = Self.normalizedSettings(maxTokens, refillInterval)
        self.maxTokens = settings.maxTokens
        self.refillInterval = settings.refillInterval
        self.clock = clock
        #if DEBUG
        self.hooks = nil
        #endif
        self.currentTokens = settings.maxTokens
        self.lastRefillInstant = clock.now
    }

    #if DEBUG
    /// Injects deterministic hooks around waiter lifecycle transitions.
    init(
        maxTokens: Int,
        refillInterval: Duration,
        clock: ContinuousClock = ContinuousClock(),
        hooks: TestHooks
    ) {
        let settings = Self.normalizedSettings(maxTokens, refillInterval)
        self.maxTokens = settings.maxTokens
        self.refillInterval = settings.refillInterval
        self.clock = clock
        self.hooks = hooks
        self.currentTokens = settings.maxTokens
        self.lastRefillInstant = clock.now
    }
    #endif

    // MARK: - RateLimiter Conformance

    /// Acquires permission to make a request.
    ///
    /// Refills tokens based on elapsed time, then either returns immediately
    /// or waits in FIFO order for a refill or explicit release.
    ///
    /// - Returns: The duration spent waiting, or `.zero` if a token was immediately available.
    public func acquire() async -> Duration {
        totalRequests += 1
        switch await reserveToken(deadline: nil, observesCancellation: false) {
        case let .granted(waitDuration):
            return waitDuration
        case .cancelled, .deadlineExceeded:
            assertionFailure("Non-cancellable acquisition reached an impossible terminal state")
            log.fault("Rate limiter reached an impossible acquisition state")
            return .zero
        }
    }

    /// Acquires a token before `deadline`.
    ///
    /// If this method throws, no token remains held. A token granted during a
    /// deadline or cancellation race is returned automatically.
    func acquire(until deadline: ContinuousClock.Instant) async throws -> Duration {
        try Task.checkCancellation()
        totalRequests += 1

        switch await reserveToken(deadline: deadline, observesCancellation: true) {
        case let .granted(waitDuration):
            #if DEBUG
            await hooks?.afterGrant?()
            #endif
            do {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw RateLimitError.deadlineExceeded
                }
            } catch {
                release()
                throw error
            }
            return waitDuration
        case .cancelled:
            throw CancellationError()
        case .deadlineExceeded:
            try Task.checkCancellation()
            throw RateLimitError.deadlineExceeded
        }
    }

    /// Reserves a token before `deadline`.
    /// Commit immediately after dispatch; cancel or abandon the lease if no request is sent.
    func reserve(until deadline: ContinuousClock.Instant) async throws -> RateLimitLease {
        _ = try await acquire(until: deadline)
        return RateLimitLease(limiter: self)
    }

    /// Returns a token to the bucket, capped at `maxTokens`.
    ///
    /// Use this for error cleanup when a request slot was acquired
    /// but the request was not actually sent.
    public func release() {
        refillTokens()
        // Drain refilled capacity first so the cap cannot discard the returned reservation.
        grantTokens()
        if currentTokens < maxTokens {
            currentTokens += 1
        }
        grantTokens()
        scheduleWake()
    }

    /// Returns statistics; request and wait totals include attempts that later fail a post-grant re-check.
    public func getStats() -> RateLimiterStats {
        refillTokens()
        grantTokens()
        scheduleWake()
        return RateLimiterStats(
            totalRequests: totalRequests,
            totalWaitTime: totalWaitTime,
            currentTokens: currentTokens
        )
    }

    // MARK: - Test Support

    /// Polls until a stable waiter count equals `count` or the timeout elapses.
    /// Transient queue states between polling intervals may not be observed.
    func waitForQueue(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        while waiters.count != count, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return waiters.count == count
    }

    // MARK: - Private

    private static func normalizedSettings(
        _ maxTokens: Int,
        _ refillInterval: Duration
    ) -> (maxTokens: Int, refillInterval: Duration) {
        (
            maxTokens: max(1, maxTokens),
            refillInterval: refillInterval > .zero ? refillInterval : .nanoseconds(1)
        )
    }

    private func reserveToken(
        deadline: ContinuousClock.Instant?,
        observesCancellation: Bool
    ) async -> WaitResult {
        refillTokens()
        grantTokens()

        if let deadline, clock.now >= deadline {
            return .deadlineExceeded
        }

        guard !waiters.isEmpty || currentTokens <= 0 else {
            currentTokens -= 1
            return .granted(.zero)
        }

        let id = UUID()
        waiterStates[id] = .registered
        guard observesCancellation else {
            return await enqueueWaiter(id: id, deadline: deadline)
        }

        return await withTaskCancellationHandler {
            #if DEBUG
            await hooks?.beforeEnqueue?()
            #endif
            return await enqueueWaiter(id: id, deadline: deadline)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func enqueueWaiter(
        id: UUID,
        deadline: ContinuousClock.Instant?
    ) async -> WaitResult {
        switch waiterStates[id] {
        case .registered:
            waiterStates[id] = .queued
        case .cancelledBeforeEnqueue:
            waiterStates.removeValue(forKey: id)
            return .cancelled
        case .queued:
            assertionFailure("Cannot enqueue a queued rate-limit waiter")
            log.fault("Rate limiter attempted to enqueue a queued waiter")
            return .cancelled
        case nil:
            assertionFailure("Cannot enqueue an unregistered rate-limit waiter")
            log.fault("Rate limiter attempted to enqueue an unregistered waiter")
            return .cancelled
        }

        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(
                id: id,
                queuedAt: clock.now,
                deadline: deadline,
                continuation: continuation
            ))
            if deadline != nil {
                deadlineWaiterCount += 1
            }
            log.debug("Rate limited: queued request")
            scheduleWake()
        }
    }

    private func grantTokens() {
        let now = clock.now
        expireWaiters(at: now)

        while currentTokens > 0, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            finishWaiter(waiter)
            currentTokens -= 1
            let waitDuration = waiter.queuedAt.duration(to: now)
            totalWaitTime += waitDuration
            log.debug("Rate limited: waited \(waitDuration, privacy: .public)")
            waiter.continuation.resume(returning: .granted(waitDuration))
        }
    }

    private func expireWaiters(at now: ContinuousClock.Instant) {
        guard deadlineWaiterCount > 0 else { return }
        guard waiters.contains(where: { waiter in
            waiter.deadline.map { $0 <= now } ?? false
        }) else { return }

        let initialCount = waiters.count
        var active: [Waiter] = []

        for waiter in waiters {
            if let deadline = waiter.deadline, deadline <= now {
                finishWaiter(waiter)
                waiter.continuation.resume(returning: .deadlineExceeded)
            } else {
                active.append(waiter)
            }
        }
        waiters = active
        let expiredCount = initialCount - active.count
        if expiredCount > 0 {
            log.debug("Rate limited: expired \(expiredCount, privacy: .public) queued requests")
        }
    }

    private func cancelWaiter(_ id: UUID) async {
        switch waiterStates[id] {
        case .registered:
            waiterStates[id] = .cancelledBeforeEnqueue
        case .queued:
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                waiterStates.removeValue(forKey: id)
                assertionFailure("Queued rate-limit waiter is missing")
                log.fault("Rate limiter lost a queued waiter")
                return
            }
            let waiter = waiters.remove(at: index)
            finishWaiter(waiter)
            log.debug("Rate limited: cancelled queued request")
            waiter.continuation.resume(returning: .cancelled)
            scheduleWake()
        case .cancelledBeforeEnqueue, nil:
            break
        }

        #if DEBUG
        await hooks?.afterCancel?()
        #endif
    }

    private func finishWaiter(_ waiter: Waiter) {
        guard waiterStates.removeValue(forKey: waiter.id) == .queued else {
            assertionFailure("Rate-limit waiter completed outside the queued state")
            log.fault("Rate limiter completed a waiter in an invalid state")
            return
        }
        if waiter.deadline != nil {
            deadlineWaiterCount -= 1
            assert(deadlineWaiterCount >= 0)
        }
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeID = nil

        guard !waiters.isEmpty else { return }

        let refillAt = lastRefillInstant.advanced(by: refillInterval)
        let deadline = waiters.compactMap(\.deadline).min()
        let wakeAt = deadline.map { min($0, refillAt) } ?? refillAt
        let id = UUID()
        wakeID = id
        wakeTask = Task { [clock, weak self] in
            do {
                try await clock.sleep(until: wakeAt)
            } catch {
                return
            }
            await self?.wake(id)
        }
    }

    private func wake(_ id: UUID) {
        guard wakeID == id else { return }
        wakeTask = nil
        wakeID = nil
        refillTokens()
        grantTokens()
        scheduleWake()
    }

    /// Refills tokens based on elapsed time since the last refill.
    private func refillTokens() {
        let now = clock.now
        let elapsed = lastRefillInstant.duration(to: now)

        guard elapsed >= refillInterval else { return }

        let tokensToAdd = tokenCount(for: elapsed)

        if tokensToAdd > 0 {
            currentTokens = min(currentTokens + tokensToAdd, maxTokens)
            // Advance lastRefillInstant by the number of full intervals consumed
            let intervalsConsumed = tokensToAdd
            lastRefillInstant = lastRefillInstant.advanced(
                by: refillInterval * intervalsConsumed
            )
        }
    }

    /// Calculates how many whole tokens should be added for a given elapsed duration.
    ///
    /// Nanosecond arithmetic is safe for durations up to ~292 years (Int64 range).
    /// API rate limiters operate on sub-minute intervals, well within bounds.
    private func tokenCount(for elapsed: Duration) -> Int {
        let intervalNanoseconds = refillInterval.components.seconds * 1_000_000_000
            + refillInterval.components.attoseconds / 1_000_000_000
        let elapsedNanoseconds = elapsed.components.seconds * 1_000_000_000
            + elapsed.components.attoseconds / 1_000_000_000

        guard intervalNanoseconds > 0 else { return 0 }

        return Int(elapsedNanoseconds / intervalNanoseconds)
    }
}

extension Duration {
    /// Multiplies a duration by an integer scalar.
    fileprivate static func * (lhs: Duration, rhs: Int) -> Duration {
        let nanos = lhs.components.seconds * 1_000_000_000
            + lhs.components.attoseconds / 1_000_000_000
        return .nanoseconds(nanos * Int64(rhs))
    }
}
