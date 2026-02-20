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
    // MARK: - Properties

    private let maxTokens: Int
    private let refillInterval: Duration
    private let clock: ContinuousClock

    private var currentTokens: Int
    private var lastRefillInstant: ContinuousClock.Instant
    private var totalRequests: Int = 0
    private var totalWaitTime: Duration = .zero

    private let log = Logger(subsystem: "com.genreupdater", category: "RateLimiter")

    // MARK: - Initialization

    /// Creates a token-bucket rate limiter.
    ///
    /// - Parameters:
    ///   - maxTokens: Maximum number of tokens in the bucket (burst capacity).
    ///   - refillInterval: Time between individual token refills.
    ///   - clock: Clock used for timing. Defaults to `ContinuousClock()`.
    public init(
        maxTokens: Int,
        refillInterval: Duration,
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.maxTokens = maxTokens
        self.refillInterval = refillInterval
        self.clock = clock
        self.currentTokens = maxTokens
        self.lastRefillInstant = clock.now
    }

    // MARK: - RateLimiter Conformance

    /// Acquires permission to make a request.
    ///
    /// Refills tokens based on elapsed time, then either returns immediately
    /// (if a token is available) or sleeps until the next token refills.
    ///
    /// - Returns: The duration spent waiting, or `.zero` if a token was immediately available.
    public func acquire() async -> Duration {
        refillTokens()

        totalRequests += 1

        if currentTokens > 0 {
            currentTokens -= 1
            return .zero
        }

        // No tokens available — calculate wait until next refill
        let elapsed = lastRefillInstant.duration(to: clock.now)
        let timeSinceLastRefill = elapsed.truncatingRemainder(dividingBy: refillInterval)
        let waitDuration = refillInterval - timeSinceLastRefill

        log.debug("Rate limited: waiting \(waitDuration, privacy: .public)")

        try? await clock.sleep(for: waitDuration)

        let actualWait = waitDuration
        totalWaitTime += actualWait

        // After sleeping, refill and consume
        refillTokens()
        if currentTokens > 0 {
            currentTokens -= 1
        }

        return actualWait
    }

    /// Returns a token to the bucket, capped at `maxTokens`.
    ///
    /// Use this for error cleanup when a request slot was acquired
    /// but the request was not actually sent.
    public func release() {
        if currentTokens < maxTokens {
            currentTokens += 1
        }
    }

    /// Returns current rate limiter statistics.
    public func getStats() -> RateLimiterStats {
        refillTokens()
        return RateLimiterStats(
            totalRequests: totalRequests,
            totalWaitTime: totalWaitTime,
            currentTokens: currentTokens
        )
    }

    // MARK: - Private

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
    private func tokenCount(for elapsed: Duration) -> Int {
        let intervalNanoseconds = refillInterval.components.seconds * 1_000_000_000
            + refillInterval.components.attoseconds / 1_000_000_000
        let elapsedNanoseconds = elapsed.components.seconds * 1_000_000_000
            + elapsed.components.attoseconds / 1_000_000_000

        guard intervalNanoseconds > 0 else { return 0 }

        return Int(elapsedNanoseconds / intervalNanoseconds)
    }
}

// MARK: - Duration Arithmetic Helpers

extension Duration {
    /// Returns the remainder after dividing this duration by the given divisor.
    fileprivate func truncatingRemainder(dividingBy divisor: Duration) -> Duration {
        let selfNanos = self.components.seconds * 1_000_000_000
            + self.components.attoseconds / 1_000_000_000
        let divisorNanos = divisor.components.seconds * 1_000_000_000
            + divisor.components.attoseconds / 1_000_000_000

        guard divisorNanos > 0 else { return self }

        let remainderNanos = selfNanos % divisorNanos
        return .nanoseconds(remainderNanos)
    }

    /// Multiplies a duration by an integer scalar.
    fileprivate static func * (lhs: Duration, rhs: Int) -> Duration {
        let nanos = lhs.components.seconds * 1_000_000_000
            + lhs.components.attoseconds / 1_000_000_000
        return .nanoseconds(nanos * Int64(rhs))
    }
}
