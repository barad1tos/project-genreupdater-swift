import Foundation
import Testing
@testable import Services

@Suite("Rate lease ownership")
struct RateLeaseTests {
    @Test("Cancelling a reservation returns exactly one token")
    func cancelReturnsOneToken() async throws {
        let clock = ManualClock()
        let queue = EventCounter()
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(300),
            hooks: .init(
                afterEnqueue: { queue.record() },
                now: { clock.now }
            )
        )
        let firstDeadline = clock.now.advanced(by: .seconds(120))
        let expiredDeadline = clock.now.advanced(by: .seconds(60))
        let lease = try await limiter.reserve(
            until: firstDeadline
        )

        let first = Task {
            try await limiter.acquire(until: firstDeadline)
        }
        #expect(await queue.wait(for: 1))
        let second = Task {
            try await limiter.acquire(until: expiredDeadline)
        }
        #expect(await queue.wait(for: 2))

        clock.advance(past: expiredDeadline)
        await lease.cancel()
        await lease.cancel()

        #expect(try await first.value > .zero)
        await #expect(throws: RateLimitError.self) {
            _ = try await second.value
        }
        #expect(await limiter.getStats().currentTokens == 0)
    }

    @Test("Abandoned reservation returns its token")
    func abandonedLeaseReturnsToken() async throws {
        let clock = ManualClock()
        let queue = EventCounter()
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(300),
            hooks: .init(
                afterEnqueue: { queue.record() },
                now: { clock.now }
            )
        )
        let deadline = clock.now.advanced(by: .seconds(120))
        var lease: RateLimitLease? = try await limiter.reserve(
            until: deadline
        )

        let next = Task {
            try await limiter.acquire(until: deadline)
        }
        #expect(await queue.wait(for: 1))

        #expect(lease != nil)
        lease = nil

        _ = try await next.value
        #expect(await limiter.getStats().currentTokens == 0)
    }

    @Test("Committed reservation keeps its consumed token")
    func committedLeaseKeepsToken() async throws {
        let clock = ManualClock()
        let queue = EventCounter()
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(300),
            hooks: .init(
                afterEnqueue: { queue.record() },
                now: { clock.now }
            )
        )
        let reservationDeadline = clock.now.advanced(by: .seconds(120))
        var lease: RateLimitLease? = try await limiter.reserve(
            until: reservationDeadline
        )
        lease?.dispatch {
            // This test consumes the reservation without an unrelated request side effect.
        }

        let blockedDeadline = clock.now.advanced(by: .seconds(60))
        let next = Task {
            try await limiter.acquire(until: blockedDeadline)
        }
        #expect(await queue.wait(for: 1))

        await lease?.cancel()
        lease = nil
        clock.advance(past: blockedDeadline)
        _ = await limiter.getStats()

        await #expect(throws: RateLimitError.self) {
            _ = try await next.value
        }
        await limiter.release()
        #expect(try await limiter.acquire(until: reservationDeadline) == .zero)
    }

    @Test("Cancellation after dispatch keeps the consumed token")
    func retainsConsumedToken() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(30))
        let lease = try await limiter.reserve(
            until: ContinuousClock().now.advanced(by: .seconds(1))
        )
        let cancellation = DispatchCancellation()

        let didDispatch = lease.dispatch {
            cancellation.start { await lease.cancel() }
        }
        #expect(didDispatch)
        await cancellation.wait()

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 0)
    }
}

// Safety: the lock protects the test clock instant and every access to it.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(past deadline: ContinuousClock.Instant) {
        lock.withLock { instant = deadline.advanced(by: .nanoseconds(1)) }
    }
}

private actor DispatchCancellation {
    private var task: Task<Void, Never>?

    nonisolated func start(_ operation: @escaping @Sendable () async -> Void) {
        Task { await self.store(Task(operation: operation)) }
    }

    func wait() async {
        while task == nil {
            await Task.yield()
        }
        await task?.value
    }

    private func store(_ task: Task<Void, Never>) {
        self.task = task
    }
}
