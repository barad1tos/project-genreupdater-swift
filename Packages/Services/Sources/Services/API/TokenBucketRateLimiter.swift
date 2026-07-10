import Core
import OSLog

/// Token-bucket rate limiter for throttling API requests.
///
/// Each instance is configured with a maximum token count and a refill interval.
/// Tokens are consumed by `acquire()` and refilled one-per-interval automatically.
/// Typical configurations:
/// - MusicBrainz: `maxTokens: 1, refillInterval: .seconds(1)` (1 req/sec)
/// - Discogs: `maxTokens: 60, refillInterval: .seconds(60)` (60 req/min)
public actor TokenBucketRateLimiter: RateLimiter {
    private struct Waiter {
        let queuedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<Duration, Never>
    }

    private struct QueueObserver {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    // MARK: - Properties

    private let maxTokens: Int
    private let refillInterval: Duration
    private let clock: ContinuousClock

    private var currentTokens: Int
    private var lastRefillInstant: ContinuousClock.Instant
    private var totalRequests: Int = 0
    private var totalWaitTime: Duration = .zero
    private var waiters: [Waiter] = []
    private var wakeTask: Task<Void, Never>?
    private var wakeID: UUID?
    private var queueObservers: [QueueObserver] = []

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
        let tokenLimit = max(1, maxTokens)
        self.maxTokens = tokenLimit
        self.refillInterval = refillInterval > .zero ? refillInterval : .nanoseconds(1)
        self.clock = clock
        self.currentTokens = tokenLimit
        self.lastRefillInstant = clock.now
    }

    // MARK: - RateLimiter Conformance

    /// Acquires permission to make a request.
    ///
    /// Refills tokens based on elapsed time, then either returns immediately
    /// or waits in FIFO order for a refill or explicit release.
    ///
    /// - Returns: The duration spent waiting, or `.zero` if a token was immediately available.
    public func acquire() async -> Duration {
        totalRequests += 1
        return await reserveToken()
    }

    /// Returns a token to the bucket, capped at `maxTokens`.
    ///
    /// Use this for error cleanup when a request slot was acquired
    /// but the request was not actually sent.
    public func release() {
        refillTokens()
        if currentTokens < maxTokens {
            currentTokens += 1
        }
        grantTokens()
        scheduleWake()
    }

    /// Returns current rate limiter statistics.
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

    // MARK: - Private

    func waitForQueue(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        if waiters.count >= count {
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.expireObserver(id)
                }
                queueObservers.append(QueueObserver(
                    id: id,
                    count: count,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                ))
            }
        } onCancel: {
            Task { await self.cancelObserver(id) }
        }
    }

    private func reserveToken() async -> Duration {
        refillTokens()
        grantTokens()

        guard !waiters.isEmpty || currentTokens <= 0 else {
            currentTokens -= 1
            return .zero
        }

        return await enqueueWaiter()
    }

    private func enqueueWaiter() async -> Duration {
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(
                queuedAt: clock.now,
                continuation: continuation
            ))
            log.debug("Rate limited: queued request")
            notifyQueueObservers()
            scheduleWake()
        }
    }

    private func grantTokens() {
        let now = clock.now

        while currentTokens > 0, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            currentTokens -= 1
            let waitDuration = waiter.queuedAt.duration(to: now)
            totalWaitTime += waitDuration
            log.debug("Rate limited: waited \(waitDuration, privacy: .public)")
            waiter.continuation.resume(returning: waitDuration)
        }
        notifyQueueObservers()
    }

    private func expireObserver(_ id: UUID) {
        finishObserver(id, result: false)
    }

    private func cancelObserver(_ id: UUID) {
        finishObserver(id, result: false)
    }

    private func finishObserver(_ id: UUID, result: Bool) {
        guard let index = queueObservers.firstIndex(where: { $0.id == id }) else { return }
        let observer = queueObservers.remove(at: index)
        observer.timeoutTask.cancel()
        observer.continuation.resume(returning: result)
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeID = nil

        guard !waiters.isEmpty else { return }

        let wakeAt = lastRefillInstant.advanced(by: refillInterval)
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

    private func notifyQueueObservers() {
        var pending: [QueueObserver] = []
        for observer in queueObservers {
            if waiters.count >= observer.count {
                observer.timeoutTask.cancel()
                observer.continuation.resume(returning: true)
            } else {
                pending.append(observer)
            }
        }
        queueObservers = pending
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
