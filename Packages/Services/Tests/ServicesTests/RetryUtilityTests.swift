import Foundation
import Testing
@testable import Services

// MARK: - Test Errors

/// Non-retryable error for testing.
private enum TestError: Error {
    case nonRetryable
    case customRetryable
}

@Suite("withRetry — exponential backoff with jitter")
struct RetryUtilityTests {
    // MARK: - Success Paths

    @Test("Returns result on first attempt when operation succeeds")
    func successOnFirstAttempt() async throws {
        let result = try await withRetry(
            maxAttempts: 3,
            initialDelay: .milliseconds(10)
        ) {
            42
        }

        #expect(result == 42)
    }

    @Test("Succeeds after transient failure on retry")
    func successAfterTransientFailure() async throws {
        let attemptCounter = AtomicCounter()

        let result = try await withRetry(
            maxAttempts: 3,
            initialDelay: .milliseconds(10)
        ) {
            let attempt = await attemptCounter.increment()
            if attempt == 1 {
                throw MusicBrainzError.serviceUnavailable
            }
            return "recovered"
        }

        #expect(result == "recovered")
        let finalCount = await attemptCounter.value
        #expect(finalCount == 2)
    }

    // MARK: - Failure Paths

    @Test("Non-retryable error throws immediately without retrying")
    func nonRetryableErrorThrowsImmediately() async {
        let attemptCounter = AtomicCounter()

        await #expect(throws: MusicBrainzError.self) {
            try await withRetry(
                maxAttempts: 3,
                initialDelay: .milliseconds(10)
            ) {
                await attemptCounter.increment()
                throw MusicBrainzError.badRequest
            }
        }

        let finalCount = await attemptCounter.value
        #expect(finalCount == 1)
    }

    @Test("Throws last error after all attempts are exhausted")
    func maxAttemptsExhausted() async {
        let attemptCounter = AtomicCounter()

        await #expect(throws: MusicBrainzError.self) {
            try await withRetry(
                maxAttempts: 3,
                initialDelay: .milliseconds(10)
            ) {
                await attemptCounter.increment()
                throw MusicBrainzError.serviceUnavailable
            }
        }

        let finalCount = await attemptCounter.value
        #expect(finalCount == 3)
    }

    // MARK: - Cancellation

    @Test("Respects task cancellation between retries")
    func cancellationRespected() async {
        let attemptCounter = AtomicCounter()

        let task = Task {
            try await withRetry(
                maxAttempts: 5,
                initialDelay: .milliseconds(100)
            ) {
                await attemptCounter.increment()
                throw MusicBrainzError.serviceUnavailable
            }
        }

        // Allow the first attempt to fail, then cancel during the delay
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let taskResult = await task.result
        #expect(throws: CancellationError.self) { try taskResult.get() }

        // Should have attempted at most twice (first attempt + possibly one retry
        // before cancellation is detected during sleep)
        let finalCount = await attemptCounter.value
        #expect(finalCount <= 2)
    }

    // MARK: - Backoff Timing

    @Test("Delays increase exponentially between attempts")
    func exponentialBackoff() async {
        let attemptCounter = AtomicCounter()
        let initialDelay = Duration.milliseconds(50)

        let start = ContinuousClock.now

        await #expect(throws: DiscogsError.self) {
            try await withRetry(
                maxAttempts: 3,
                initialDelay: initialDelay
            ) {
                await attemptCounter.increment()
                throw DiscogsError.rateLimited
            }
        }

        let elapsed = ContinuousClock.now - start
        let finalCount = await attemptCounter.value
        #expect(finalCount == 3)

        // 3 attempts = 2 delays: ~50ms + ~100ms = ~150ms minimum (before jitter).
        // With -25% jitter: 37.5ms + 75ms = 112.5ms.
        // With +25% jitter: 62.5ms + 125ms = 187.5ms.
        // Allow generous tolerance for CI variance.
        #expect(elapsed >= .milliseconds(80))
        #expect(elapsed < .milliseconds(500))
    }

    // MARK: - Custom Classifier

    @Test("Custom shouldRetry classifier overrides default behavior")
    func customShouldRetry() async {
        let attemptCounter = AtomicCounter()

        let result = try? await withRetry(
            maxAttempts: 3,
            initialDelay: .milliseconds(10),
            shouldRetry: { error in
                // Treat our custom error as retryable (default classifier would not)
                error is TestError
            },
            operation: {
                let attempt = await attemptCounter.increment()
                if attempt < 3 {
                    throw TestError.customRetryable
                }
                return "custom-recovered"
            }
        )

        #expect(result == "custom-recovered")
        let finalCount = await attemptCounter.value
        #expect(finalCount == 3)
    }
}

// MARK: - isTransientError Classifier Tests

@Suite("isTransientError — error classification for retry decisions")
struct TransientErrorClassifierTests {
    @Test("MusicBrainzError.serviceUnavailable is transient")
    func musicBrainzServiceUnavailable() {
        #expect(isTransientError(MusicBrainzError.serviceUnavailable) == true)
    }

    @Test("MusicBrainzError.badRequest is NOT transient")
    func musicBrainzBadRequest() {
        #expect(isTransientError(MusicBrainzError.badRequest) == false)
    }

    @Test("MusicBrainzError.invalidResponse is NOT transient")
    func musicBrainzInvalidResponse() {
        #expect(isTransientError(MusicBrainzError.invalidResponse) == false)
    }

    @Test("MusicBrainzError.httpError is NOT transient")
    func musicBrainzHttpError() {
        #expect(isTransientError(MusicBrainzError.httpError(500)) == false)
    }

    @Test("DiscogsError.rateLimited is transient")
    func discogsRateLimited() {
        #expect(isTransientError(DiscogsError.rateLimited) == true)
    }

    @Test("DiscogsError.noToken is NOT transient")
    func discogsNoToken() {
        #expect(isTransientError(DiscogsError.noToken) == false)
    }

    @Test("DiscogsError.unauthorized is NOT transient")
    func discogsUnauthorized() {
        #expect(isTransientError(DiscogsError.unauthorized) == false)
    }

    @Test(
        "URLError transient codes are retryable",
        arguments: [
            URLError.Code.timedOut,
            URLError.Code.networkConnectionLost,
            URLError.Code.notConnectedToInternet,
            URLError.Code.cannotConnectToHost,
        ]
    )
    func urlErrorTransientCodes(code: URLError.Code) {
        #expect(isTransientError(URLError(code)) == true)
    }

    @Test(
        "URLError non-transient codes are NOT retryable",
        arguments: [
            URLError.Code.badURL,
            URLError.Code.cancelled,
            URLError.Code.badServerResponse,
        ]
    )
    func urlErrorNonTransientCodes(code: URLError.Code) {
        #expect(isTransientError(URLError(code)) == false)
    }

    @Test("Unknown error types are NOT transient")
    func unknownErrors() {
        #expect(isTransientError(TestError.nonRetryable) == false)
    }
}

// MARK: - Test Helpers

/// Thread-safe counter for tracking attempt counts across async boundaries.
private actor AtomicCounter {
    private(set) var value: Int = 0

    /// Increments the counter and returns the new value.
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
