import Testing
@testable import Services

@Suite("Rate lease ownership", .serialized)
struct RateLeaseTests {
    @Test("Cancelling a reservation returns exactly one token")
    func cancelReturnsOneToken() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(30)
        )
        let clock = ContinuousClock()
        let lease = try await limiter.reserve(
            until: clock.now.advanced(by: .seconds(2))
        )

        let first = Task {
            try await limiter.acquire(until: clock.now.advanced(by: .seconds(2)))
        }
        #expect(await limiter.waitForQueue(1))
        let second = Task {
            try await limiter.acquire(until: clock.now.advanced(by: .milliseconds(250)))
        }
        #expect(await limiter.waitForQueue(2))

        await lease.cancel()
        await lease.cancel()

        #expect(try await first.value > .zero)
        await #expect(throws: RateLimitError.self) {
            _ = try await second.value
        }
    }

    @Test("Abandoned reservation returns its token")
    func abandonedLeaseReturnsToken() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(30)
        )
        let clock = ContinuousClock()
        var lease: RateLimitLease? = try await limiter.reserve(
            until: clock.now.advanced(by: .seconds(2))
        )

        let next = Task {
            try await limiter.acquire(until: clock.now.advanced(by: .seconds(2)))
        }
        #expect(await limiter.waitForQueue(1))

        withExtendedLifetime(lease) {}
        lease = nil

        guard await limiter.waitForQueue(0, timeout: .milliseconds(500)) else {
            next.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await next.value
            }
            Issue.record("Expected abandoned lease to return its token")
            return
        }
        #expect(try await next.value > .zero)
    }

    @Test("Committed reservation keeps its consumed token")
    func committedLeaseKeepsToken() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(30)
        )
        let clock = ContinuousClock()
        var lease: RateLimitLease? = try await limiter.reserve(
            until: clock.now.advanced(by: .seconds(2))
        )
        lease?.commit()

        let next = Task {
            try await limiter.acquire(until: clock.now.advanced(by: .milliseconds(250)))
        }
        #expect(await limiter.waitForQueue(1))

        await lease?.cancel()
        lease = nil

        await #expect(throws: RateLimitError.self) {
            _ = try await next.value
        }
        await limiter.release()
        #expect(try await limiter.acquire(until: clock.now.advanced(by: .seconds(1))) == .zero)
    }
}
