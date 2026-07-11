import Core
import Foundation
import OSLog

private let dispatchLog = AppLogger.make(category: "applescript.dispatch")

// Safety: each wrapped value is confined to one bounded script execution.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

struct ScriptCall: Sendable {
    let name: String
    let intent: ScriptIntent
    let deadline: ContinuousClock.Instant
    let timeout: Duration
}

/// A dispatched mutation whose physical result stayed unknown past its safety ceiling.
public struct AppleScriptOutcomeError: Error, LocalizedError, Sendable {
    public let scriptName: String
    public let duration: Duration

    public var errorDescription: String? {
        "AppleScript '\(scriptName)' did not return within \(duration); its outcome is unknown"
    }
}

enum ScriptDispatch {
    private static let mutationOutcomeFactor = 3

    static func run<Value: Sendable>(
        _ call: ScriptCall,
        limiter: TokenBucketRateLimiter?,
        gate: ScriptGate,
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        let lease = try await reserveToken(for: call, limiter: limiter)
        let permit: ScriptPermit
        do {
            permit = try await gate.acquire(
                scriptName: call.name,
                deadline: call.deadline,
                timeout: call.timeout
            )
        } catch {
            await lease?.cancel()
            throw error
        }

        do {
            return try await ScriptTask.run(
                policy: policy(for: call),
                onOwnershipReleased: { permit.release() },
                start: { finish in
                    if let lease {
                        guard lease.dispatch({ start(finish) }) else {
                            finish(.failure(call.dispatchError))
                            return
                        }
                    } else {
                        start(finish)
                    }
                }
            )
        } catch {
            await lease?.cancel()
            throw error
        }
    }

    private static func reserveToken(
        for call: ScriptCall,
        limiter: TokenBucketRateLimiter?
    ) async throws -> RateLimitLease? {
        guard let limiter else { return nil }
        do {
            return try await limiter.reserve(until: call.deadline)
        } catch RateLimitError.deadlineExceeded {
            throw AppleScriptBridgeError.dispatchDeadline(
                scriptName: call.name,
                duration: call.timeout
            )
        }
    }

    private static func policy(for call: ScriptCall) -> ScriptTaskPolicy {
        let dispatchError: @Sendable () -> any Error = {
            AppleScriptBridgeError.dispatchDeadline(
                scriptName: call.name,
                duration: call.timeout
            )
        }
        let intentLabel = String(describing: call.intent)
        let onDeadline: @Sendable (Duration) -> Void = { overdue in
            dispatchLog.error(
                "Pending \(intentLabel, privacy: .public): \(call.name, privacy: .public), overdue \(overdue, privacy: .public)"
            )
        }

        switch call.intent {
        case .read:
            return .read(
                deadline: call.deadline,
                dispatchError: dispatchError,
                timeoutError: {
                    AppleScriptBridgeError.timeout(
                        scriptName: call.name,
                        duration: call.timeout
                    )
                },
                onDeadline: onDeadline
            )
        case .mutation:
            // A write gets a bounded grace window for its physical callback after caller timeout.
            let outcomeDuration = call.timeout * mutationOutcomeFactor
            return .mutation(
                deadline: call.deadline,
                dispatchError: dispatchError,
                outcome: ScriptTaskOutcome(
                    deadline: ContinuousClock().now.advanced(by: outcomeDuration),
                    error: {
                        AppleScriptOutcomeError(
                            scriptName: call.name,
                            duration: outcomeDuration
                        )
                    }
                ),
                onDeadline: onDeadline
            )
        }
    }
}

extension AppleScriptBridge {
    func executeScriptAttempt(
        _ call: ScriptCall,
        scriptURL: URL,
        arguments: [String]
    ) async throws -> String? {
        let task = try NSUserAppleScriptTask(url: scriptURL)
        let event = Self.makeRunAppleEvent(arguments: arguments)
        let wrappedTask = UnsafeSendable(value: task)
        let wrappedEvent = UnsafeSendable(value: event)

        return try await dispatchScript(call) { finish in
            wrappedTask.value.execute(withAppleEvent: wrappedEvent.value) { descriptor, error in
                _ = wrappedTask
                _ = wrappedEvent
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(descriptor?.stringValue))
                }
            }
        }
    }
}

extension ScriptCall {
    fileprivate var dispatchError: AppleScriptBridgeError {
        .dispatchDeadline(scriptName: name, duration: timeout)
    }
}
