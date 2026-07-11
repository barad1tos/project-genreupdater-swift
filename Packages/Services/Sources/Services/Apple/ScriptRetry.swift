import Core
import Foundation
import OSLog

private let retryLog = AppLogger.make(category: "applescript.retry")

extension AppleScriptBridge {
    static let scriptIntents: [String: ScriptIntent] = [
        "batch_update_tracks": .mutation,
        "fetch_track_ids": .read,
        "fetch_tracks": .read,
        "fetch_tracks_by_ids": .read,
        "update_property": .mutation
    ]

    static func intent(forScript name: String) -> ScriptIntent {
        scriptIntents[name] ?? .mutation
    }

    func executeByIntent<T: Sendable>(
        scriptName: String,
        retry: AppleScriptRetry,
        deadline: ContinuousClock.Instant,
        timeout: Duration,
        operation: (Duration) async throws -> T
    ) async throws -> T {
        // Writes surface their first outcome so recovery can verify Music.app state before any replay.
        guard Self.intent(forScript: scriptName) == .read else {
            return try await operation(timeout)
        }
        return try await retryRead(
            scriptName: scriptName,
            retry: retry,
            deadline: deadline,
            timeout: timeout,
            operation: operation
        )
    }

    /// Retries fast transient read failures. A timeout that consumes the caller deadline is surfaced unchanged.
    func retryRead<T: Sendable>(
        scriptName: String,
        retry: AppleScriptRetry,
        deadline: ContinuousClock.Instant,
        timeout: Duration,
        operation: (Duration) async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let maxRetries = max(0, retry.maxRetries)
        let retryTimeout = Self.duration(seconds: retry.operationTimeoutSeconds)
        let retryDeadline = maxRetries > 0 && retry.operationTimeoutSeconds > 0
            ? startedAt.advanced(by: retryTimeout)
            : nil
        var delaySeconds = max(0, retry.baseDelaySeconds)
        var lastError: (any Error)?
        var lastDispatchedError: (any Error)?

        for attempt in 0 ... maxRetries {
            let activeRetryDeadline = attempt > 0 ? retryDeadline : nil
            let now = clock.now
            if now >= deadline {
                if let error = lastDispatchedError ?? lastError {
                    throw error
                }
                throw AppleScriptBridgeError.timeout(scriptName: scriptName, duration: timeout)
            }
            if let activeRetryDeadline, now >= activeRetryDeadline {
                retryLog.warning(
                    "Read retry budget exhausted for \(scriptName, privacy: .public) before attempt \(attempt + 1, privacy: .public)"
                )
                if let error = lastDispatchedError ?? lastError {
                    throw error
                }
                throw AppleScriptBridgeError.timeout(scriptName: scriptName, duration: retryTimeout)
            }
            if attempt > 0 {
                Self.logRetry(scriptName: scriptName, attempt: attempt)
            }

            do {
                return try await operation(now.duration(to: deadline))
            } catch {
                lastError = error
                lastDispatchedError = Self.dispatchedError(from: error, previous: lastDispatchedError)
                guard attempt < maxRetries, Self.isRetryable(error) else {
                    throw lastDispatchedError ?? error
                }

                let delay = Self.retryDelay(
                    attempt: attempt,
                    baseSeconds: delaySeconds,
                    jitter: retry.jitterRange
                )
                guard try await Self.waitForRetry(
                    scriptName: scriptName,
                    attempt: attempt,
                    delay: delay,
                    deadline: deadline,
                    retryDeadline: retryDeadline
                ) else {
                    throw lastDispatchedError ?? error
                }
                delaySeconds = min(max(0, retry.maxDelaySeconds), max(0, delaySeconds * 2))
            }
        }

        throw AppleScriptBridgeError.executionFailed(
            scriptName: scriptName,
            detail: "Retry loop exited without a result"
        )
    }

    private static func logRetry(scriptName: String, attempt: Int) {
        retryLog.debug(
            "Retrying read \(scriptName, privacy: .public) after attempt \(attempt, privacy: .public) failed"
        )
    }

    private static func dispatchedError(from error: any Error, previous: (any Error)?) -> (any Error)? {
        isDispatchDeadline(error) ? previous : error
    }

    private static func waitForRetry(
        scriptName: String,
        attempt: Int,
        delay: Double,
        deadline: ContinuousClock.Instant,
        retryDeadline: ContinuousClock.Instant?
    ) async throws -> Bool {
        let sleepDuration = duration(seconds: delay)
        guard sleepDuration > .zero else { return true }

        let sleepLimit = earliest(deadline, retryDeadline)
        guard sleepDuration < ContinuousClock().now.duration(to: sleepLimit) else {
            retryLog.warning(
                "Read retry budget exhausted for \(scriptName, privacy: .public) after attempt \(attempt + 1, privacy: .public)"
            )
            return false
        }
        try await Task.sleep(for: sleepDuration)
        return true
    }

    static func isRetryable(_ error: any Error) -> Bool {
        guard let bridgeError = error as? AppleScriptBridgeError else {
            return isTransientError(error)
        }

        switch bridgeError {
        case .dispatchDeadline, .executionFailed, .musicAppNotRunning, .timeout:
            return true
        case .parseError, .scriptNotFound, .scriptsNotInstalled:
            return false
        }
    }

    static func isDispatchDeadline(_ error: any Error) -> Bool {
        guard let bridgeError = error as? AppleScriptBridgeError else { return false }
        if case .dispatchDeadline = bridgeError {
            return true
        }
        return false
    }

    static func retryDelay(attempt: Int, baseSeconds: Double, jitter: Double) -> Double {
        let baseDelay = max(0, baseSeconds)
        let clampedJitter = min(max(0, jitter), 1)
        let jitterSeed = Double((attempt * 31 + 17) % 100) / 100
        let jitterOffset = (jitterSeed - 0.5) * 2 * baseDelay * clampedJitter
        return max(0, baseDelay + jitterOffset)
    }

    private static func earliest(
        _ deadline: ContinuousClock.Instant,
        _ retryDeadline: ContinuousClock.Instant?
    ) -> ContinuousClock.Instant {
        guard let retryDeadline else { return deadline }
        return min(deadline, retryDeadline)
    }

    private static func duration(seconds: Double) -> Duration {
        .milliseconds(max(0, Int(seconds * 1000)))
    }
}
