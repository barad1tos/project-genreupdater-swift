import Testing
@testable import Services

@Suite("TokenBucketRateLimiter — token-bucket rate limiting")
struct RateLimiterTests {
    @Test("Nonpositive limits normalize to usable minimums")
    func normalizesInvalidLimits() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 0, refillInterval: .zero)

        let stats = await limiter.getStats()

        #expect(stats.currentTokens == 1)
        #expect(await limiter.acquire() == .zero)
    }

    // MARK: - Acquire

    @Test("Acquire returns zero wait when tokens are available")
    func acquiresImmediately() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 5, refillInterval: .seconds(60))

        let waitTime = await limiter.acquire()
        #expect(waitTime == .zero)

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 4)
        #expect(stats.totalRequests == 1)
    }

    @Test("Acquire waits when no tokens are available")
    func waitsWhenEmpty() async {
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

    @Test("Concurrent waiters receive explicitly released tokens in FIFO order")
    func grantsInOrder() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )
        _ = await limiter.acquire()

        await withTaskGroup(of: Int.self) { group in
            group.addTask {
                _ = await limiter.acquire()
                return 1
            }
            #expect(await limiter.waitForQueue(1))
            group.addTask {
                _ = await limiter.acquire()
                return 2
            }
            #expect(await limiter.waitForQueue(2))
            group.addTask {
                _ = await limiter.acquire()
                return 3
            }
            #expect(await limiter.waitForQueue(3))

            await limiter.release()
            #expect(await group.next() == 1)
            await limiter.release()
            #expect(await group.next() == 2)
            await limiter.release()
            #expect(await group.next() == 3)
        }
    }

    @Test("Queued waiters advance across automatic refills")
    func refillsQueuedWaiters() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .milliseconds(100)
        )
        let probe = RateOrderProbe()
        _ = await limiter.acquire()

        for value in 1 ... 3 {
            Task {
                _ = await limiter.acquire()
                await probe.record(value)
            }
            #expect(await limiter.waitForQueue(value))
        }

        #expect(await probe.waitForValues(3) == [1, 2, 3])
    }

    @Test("Cancelled protocol acquire still returns a real token")
    func cancellationKeepsReservation() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )
        _ = await limiter.acquire()

        let cancelled = Task { await limiter.acquire() }
        #expect(await limiter.waitForQueue(1))
        cancelled.cancel()

        await limiter.release()
        #expect(await cancelled.value > .zero)

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 0)
        #expect(stats.totalRequests == 2)
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
    func releaseIsCapped() async {
        let limiter = TokenBucketRateLimiter(maxTokens: 3, refillInterval: .seconds(60))

        // Bucket starts full at 3 tokens — release should not add more
        await limiter.release()
        await limiter.release()

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 3)
    }

    // MARK: - Stats

    @Test("Stats track total requests and wait time")
    func tracksRequestStats() async {
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
    func refillsAfterInterval() async throws {
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

private actor RateOrderProbe {
    private var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }

    func waitForValues(_ count: Int, timeout: Duration = .seconds(1)) async -> [Int] {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while values.count < count, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return values
    }
}
