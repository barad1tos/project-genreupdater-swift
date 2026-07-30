import Core
import Foundation
import OSLog

private let dispatchLog = AppLogger.make(category: "applescript.dispatch")

// Safety: each wrapped value is confined to one bounded script execution.
// swiftformat:disable:next redundantSendable
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

struct ScriptCall {
    let name: String
    let intent: ScriptIntent
    let deadline: ContinuousClock.Instant
    let timeout: Duration
}

/// A dispatched mutation whose physical result stayed unknown past its safety ceiling.
public struct AppleScriptOutcomeError: Error, LocalizedError, Sendable {
    public let scriptName: String
    public let duration: Duration?
    public let reason: String
    let completion: ScriptCompletion?

    public init(scriptName: String, duration: Duration) {
        self.scriptName = scriptName
        self.duration = duration
        self.reason = "did not return within \(duration)"
        self.completion = nil
    }

    public init(scriptName: String, reason: String) {
        self.scriptName = scriptName
        self.duration = nil
        self.reason = reason
        self.completion = nil
    }

    init(scriptName: String, duration: Duration, completion: ScriptCompletion) {
        self.scriptName = scriptName
        self.duration = duration
        self.reason = "did not return within \(duration)"
        self.completion = completion
    }

    public var errorDescription: String? {
        "AppleScript '\(scriptName)' \(reason); its outcome is unknown"
    }
}

// Safety: the lock guards completion state and every waiter transition.
final class ScriptCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiters: Bool {
        lock.withLock { !waiters.isEmpty }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !isComplete else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func finish() {
        let pending = lock.withLock {
            guard !isComplete else { return [CheckedContinuation<Void, Never>]() }
            isComplete = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
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
        let completion = call.intent == .mutation ? ScriptCompletion() : nil
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
                policy: policy(for: call, completion: completion),
                onOwnershipReleased: {
                    permit.release()
                    completion?.finish()
                },
                start: { finish in
                    let resolve: @Sendable (Result<Value, any Error>) -> Void = { result in
                        guard call.intent == .mutation,
                              case let .failure(error) = result,
                              !(error is AppleScriptOutcomeError)
                        else {
                            finish(result)
                            return
                        }
                        finish(.failure(AppleScriptOutcomeError(
                            scriptName: call.name,
                            reason: "returned an error after dispatch: \(error.localizedDescription)"
                        )))
                    }
                    if let lease {
                        guard lease.dispatch({ start(resolve) }) else {
                            finish(.failure(call.dispatchError))
                            return
                        }
                    } else {
                        start(resolve)
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

    private static func policy(for call: ScriptCall, completion: ScriptCompletion?) -> ScriptTaskPolicy {
        let dispatchError: @Sendable () -> any Error = {
            AppleScriptBridgeError.dispatchDeadline(
                scriptName: call.name,
                duration: call.timeout
            )
        }
        let intentLabel = String(describing: call.intent)
        let onDeadline: @Sendable (Duration) -> Void = { overdue in
            dispatchLog.error(
                "\(call.name, privacy: .public) \(intentLabel, privacy: .public) overdue \(overdue, privacy: .public)"
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
            guard let completion else {
                preconditionFailure("Mutation dispatch requires a completion owner")
            }
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
                            duration: outcomeDuration,
                            completion: completion
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
