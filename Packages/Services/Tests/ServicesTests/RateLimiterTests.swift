import Testing
@testable import Services

@Suite("TokenBucketRateLimiter — token-bucket rate limiting")
struct RateLimiterTests {
    // MARK: - Acquire

    @Test("Acquire returns zero wait when tokens are available")
    func acquireReturnsZeroWaitWhenAvailable() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 5, refillInterval: .seconds(60))

        let waitTime = await limiter.acquire()
        #expect(waitTime == .zero)

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 4)
        #expect(stats.totalRequests == 1)
    }

    @Test("Acquire waits when no tokens are available")
    func acquireWaitsWhenNoTokens() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .milliseconds(100)
        )

        // Consume the single token
        let firstWait = await limiter.acquire()
        #expect(firstWait == .zero)

        // Next acquire must wait for refill
        let secondWait = await limiter.acquire()
        #expect(secondWait > .zero)

        let stats = await limiter.getStats()
        #expect(stats.totalRequests == 2)
        #expect(stats.totalWaitTime > .zero)
    }

    // MARK: - Release

    @Test("Release returns a token to the bucket")
    func releaseReturnsToken() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 2, refillInterval: .seconds(60))

        // Consume both tokens
        _ = await limiter.acquire()
        _ = await limiter.acquire()

        let depletedStats = await limiter.getStats()
        #expect(depletedStats.currentTokens == 0)

        // Release one token back
        await limiter.release()

        let afterRelease = await limiter.getStats()
        #expect(afterRelease.currentTokens == 1)
    }

    @Test("Release cannot exceed maxTokens")
    func releaseCannotExceedMax() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 3, refillInterval: .seconds(60))

        // Bucket starts full at 3 tokens — release should not add more
        await limiter.release()
        await limiter.release()

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 3)
    }

    // MARK: - Stats

    @Test("Stats track total requests and wait time")
    func statsTrackRequestsAndWaitTime() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .milliseconds(50)
        )

        // First request: no wait
        let firstWait = await limiter.acquire()
        #expect(firstWait == .zero)

        // Second request: must wait for refill
        let secondWait = await limiter.acquire()
        #expect(secondWait > .zero)

        let stats = await limiter.getStats()
        #expect(stats.totalRequests == 2)
        #expect(stats.totalWaitTime == firstWait + secondWait)
    }

    // MARK: - Refill

    @Test("Tokens refill after interval passes")
    func tokensRefillAfterInterval() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 2,
            refillInterval: .milliseconds(100)
        )

        // Consume both tokens
        _ = await limiter.acquire()
        _ = await limiter.acquire()

        let depletedStats = await limiter.getStats()
        #expect(depletedStats.currentTokens == 0)

        // Wait for one full refill interval plus margin
        try await Task.sleep(for: .milliseconds(150))

        // After interval, at least one token should have refilled.
        // Acquire should succeed without waiting (or very short wait).
        let waitTime = await limiter.acquire()

        // The refill should have provided a token, so wait should be zero
        // (or negligibly small if timing is tight).
        #expect(waitTime < .milliseconds(50))
    }
}
