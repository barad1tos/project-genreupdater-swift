import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("AppleScript retry deadlines")
struct RetryDeadlineTests {
    @Test("Retry delay cannot outlive the caller deadline")
    func delayHonorsDeadline() async {
        let bridge = makeDeadlineBridge()
        let probe = DeadlineProbe(failures: 10)
        var retry = deadlineRetryPolicy()
        retry.baseDelaySeconds = 1
        retry.maxDelaySeconds = 1
        let clock = ContinuousClock()
        let startedAt = clock.now
        let timeout = Duration.milliseconds(20)

        do {
            _ = try await bridge.retryRead(
                scriptName: "fetch_tracks",
                retry: retry,
                deadline: startedAt.advanced(by: timeout),
                timeout: timeout
            ) { _ in
                try await probe.run()
            }
            Issue.record("Expected the last read failure")
        } catch let error as AppleScriptBridgeError {
            guard case let .executionFailed(_, detail) = error else {
                Issue.record("Expected executionFailed, got \(error)")
                return
            }
            #expect(detail == "Music busy")
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }

        #expect(await probe.attempts == 1)
        #expect(startedAt.duration(to: clock.now) < .milliseconds(500))
    }

    @Test("Expired caller deadline fails before the first attempt")
    func rejectsExpiredDeadline() async {
        let bridge = makeDeadlineBridge()
        let probe = DeadlineProbe(failures: 0)
        let timeout = Duration.milliseconds(20)

        do {
            _ = try await bridge.retryRead(
                scriptName: "fetch_tracks",
                retry: deadlineRetryPolicy(),
                deadline: ContinuousClock().now.advanced(by: .milliseconds(-1)),
                timeout: timeout
            ) { _ in
                try await probe.run()
            }
            Issue.record("Expected timeout")
        } catch let error as AppleScriptBridgeError {
            guard case let .timeout(_, duration) = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
            #expect(duration == timeout)
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }

        #expect(await probe.attempts == 0)
    }

    @Test("Expired retry start budget preserves the last failure")
    func preservesFailureAfterBudget() async {
        let bridge = makeDeadlineBridge()
        let probe = DeadlineProbe(failures: 2)
        var retry = deadlineRetryPolicy()
        retry.operationTimeoutSeconds = 0.0001

        do {
            _ = try await bridge.retryRead(
                scriptName: "fetch_tracks",
                retry: retry,
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            ) { _ in
                try await probe.run()
            }
            Issue.record("Expected the last read failure")
        } catch let error as AppleScriptBridgeError {
            guard case let .executionFailed(_, detail) = error else {
                Issue.record("Expected executionFailed, got \(error)")
                return
            }
            #expect(detail == "Music busy")
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }

        #expect(await probe.attempts == 1)
    }

    @Test("A pre-dispatch retry failure preserves an earlier dispatched error")
    func preservesDispatchedFailure() async {
        let bridge = makeDeadlineBridge()
        let probe = FailureProbe(errors: [
            .executionFailed(scriptName: "fetch_tracks", detail: "Music busy"),
            .dispatchDeadline(scriptName: "fetch_tracks", duration: .seconds(1))
        ])
        var retry = deadlineRetryPolicy()
        retry.maxRetries = 1

        do {
            _ = try await bridge.retryRead(
                scriptName: "fetch_tracks",
                retry: retry,
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            ) { _ in
                try await probe.run()
            }
            Issue.record("Expected the dispatched failure")
        } catch let error as AppleScriptBridgeError {
            guard case let .executionFailed(_, detail) = error else {
                Issue.record("Expected executionFailed, got \(error)")
                return
            }
            #expect(detail == "Music busy")
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }

        #expect(await probe.attempts == 2)
    }

    @Test("Retry attempts keep the remaining caller timeout")
    func preservesCallerTimeout() async throws {
        let bridge = makeDeadlineBridge()
        let probe = TimeoutProbe()
        var retry = deadlineRetryPolicy()
        retry.maxRetries = 1
        retry.operationTimeoutSeconds = 5
        let timeout = Duration.seconds(10)

        let result = try await bridge.retryRead(
            scriptName: "fetch_tracks",
            retry: retry,
            deadline: ContinuousClock().now.advanced(by: timeout),
            timeout: timeout
        ) { attemptTimeout in
            try await probe.run(timeout: attemptTimeout)
        }

        #expect(result == "ok")
        let timeouts = await probe.timeouts
        #expect(timeouts.count == 2)
        #expect(timeouts[0] > .seconds(1))
        #expect(timeouts[1] > .seconds(1))
        #expect(timeouts[1] <= timeouts[0])
    }
}

private func makeDeadlineBridge() -> AppleScriptBridge {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RetryDeadlineTests-\(UUID().uuidString)")
    return AppleScriptBridge(
        installer: ScriptInstaller(scriptsDirectory: directory, bundleScriptsDirectory: nil)
    )
}

private func deadlineRetryPolicy() -> AppleScriptRetry {
    var retry = AppleScriptRetry()
    retry.maxRetries = 2
    retry.baseDelaySeconds = 0
    retry.maxDelaySeconds = 0
    retry.jitterRange = 0
    retry.operationTimeoutSeconds = 30
    return retry
}

private actor DeadlineProbe {
    private var failures: Int
    private(set) var attempts = 0

    init(failures: Int) {
        self.failures = failures
    }

    func run() throws -> String {
        attempts += 1
        guard failures > 0 else { return "ok" }
        failures -= 1
        throw AppleScriptBridgeError.executionFailed(scriptName: "fetch_tracks", detail: "Music busy")
    }
}

private actor TimeoutProbe {
    private(set) var timeouts: [Duration] = []

    func run(timeout: Duration) throws -> String {
        timeouts.append(timeout)
        guard timeouts.count > 1 else {
            throw AppleScriptBridgeError.executionFailed(scriptName: "fetch_tracks", detail: "Music busy")
        }
        return "ok"
    }
}

private actor FailureProbe {
    private var errors: [AppleScriptBridgeError]
    private(set) var attempts = 0

    init(errors: [AppleScriptBridgeError]) {
        self.errors = errors
    }

    func run() throws -> String {
        attempts += 1
        guard !errors.isEmpty else { return "ok" }
        throw errors.removeFirst()
    }
}
