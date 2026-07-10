import Testing
@testable import Services

@Suite("Rate limit deadlines", .serialized)
struct RateDeadlineTests {
    @Test("Deadline-aware acquire expires before refill")
    func expiresBeforeRefill() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(2)
        )
        _ = await limiter.acquire()
        let clock = ContinuousClock()
        let startedAt = clock.now

        await #expect(throws: RateLimitError.self) {
            _ = try await limiter.acquire(
                until: startedAt.advanced(by: .milliseconds(50))
            )
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }

    @Test("An expired deadline does not consume a token")
    func expiryPreservesToken() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )

        await #expect(throws: RateLimitError.self) {
            _ = try await limiter.acquire(until: ContinuousClock().now)
        }

        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 1)
    }

    @Test("An available token is granted before the deadline")
    func grantsBeforeDeadline() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))

        #expect(try await limiter.acquire(until: deadline) == .zero)
        #expect(await limiter.getStats().currentTokens == 0)
    }

    @Test("A pre-cancelled task does not count an acquisition attempt")
    func cancelledSkipsStats() async {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))

        let acquisition = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await limiter.acquire(until: deadline)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await acquisition.value
        }
        #expect(await limiter.getStats().totalRequests == 0)
    }

    @Test("Cancellation removes a waiter before token release")
    func cancellationAdvancesQueue() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )
        _ = await limiter.acquire()
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))

        let cancelled = Task { try await limiter.acquire(until: deadline) }
        #expect(await limiter.waitForQueue(1))
        let next = Task { try await limiter.acquire(until: deadline) }
        #expect(await limiter.waitForQueue(2))

        cancelled.cancel()
        #expect(await limiter.waitForQueue(1))
        await limiter.release()

        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(try await next.value > .zero)
    }

    #if DEBUG
    @Test("Cancellation after grant returns the token")
    func cancellationAfterGrant() async throws {
        let gate = GrantGate()
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(30),
            hooks: .init(afterGrant: { await gate.enter() })
        )
        _ = await limiter.acquire()
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))

        let cancelled = Task { try await limiter.acquire(until: deadline) }
        #expect(await limiter.waitForQueue(1))
        let next = Task { try await limiter.acquire(until: deadline) }
        #expect(await limiter.waitForQueue(2))

        await limiter.release()
        #expect(await gate.waitForEntry())
        cancelled.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(try await next.value > .zero)
    }

    @Test("Cancellation before enqueue is retained")
    func cancellationBeforeEnqueue() async throws {
        let enqueueGate = GrantGate()
        let cancelGate = GrantGate()
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(30),
            hooks: .init(
                beforeEnqueue: { await enqueueGate.enter() },
                afterCancel: { await cancelGate.enter() }
            )
        )
        _ = await limiter.acquire()
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))

        let cancelled = Task { try await limiter.acquire(until: deadline) }
        #expect(await enqueueGate.waitForEntry())
        cancelled.cancel()
        #expect(await cancelGate.waitForEntry())

        await enqueueGate.open()
        await cancelGate.open()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(await limiter.waitForQueue(0))

        await limiter.release()
        #expect(try await limiter.acquire(until: deadline) == .zero)
    }
    #endif

    @Test("Expired waiters do not block automatic refill")
    func deadlineAdvancesQueue() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(5)
        )
        _ = await limiter.acquire()
        let clock = ContinuousClock()
        let queuedAt = clock.now
        let firstExpiry = queuedAt.advanced(by: .seconds(1))
        let secondExpiry = queuedAt.advanced(by: .seconds(2))

        let firstExpired = Task {
            try await limiter.acquire(until: firstExpiry)
        }
        #expect(await limiter.waitForQueue(1))
        let secondExpired = Task {
            try await limiter.acquire(until: secondExpiry)
        }
        #expect(await limiter.waitForQueue(2))
        let next = Task {
            try await limiter.acquire(until: queuedAt.advanced(by: .seconds(7)))
        }
        #expect(await limiter.waitForQueue(3))
        let expiryTimeout = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            secondExpired.cancel()
        }

        await #expect(throws: RateLimitError.self) {
            _ = try await firstExpired.value
        }
        #expect(queuedAt.duration(to: clock.now) < .seconds(3))
        await #expect(throws: RateLimitError.self) {
            _ = try await secondExpired.value
        }
        expiryTimeout.cancel()
        #expect(queuedAt.duration(to: clock.now) < .seconds(4))
        #expect(try await next.value > .zero)
        #expect(queuedAt.duration(to: clock.now) >= .milliseconds(4500))
    }
}

#if DEBUG
private actor GrantGate {
    private var didEnter = false
    private var isOpen = false
    private var hold: CheckedContinuation<Void, Never>?

    func enter() async {
        didEnter = true
        guard !isOpen else { return }
        await withCheckedContinuation { hold = $0 }
    }

    func waitForEntry(timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !didEnter, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        return didEnter
    }

    func open() {
        isOpen = true
        hold?.resume()
        hold = nil
    }
}
#endif
