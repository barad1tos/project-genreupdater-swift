import Core
import Foundation
import Testing
@testable import Services

@Suite("Batch dispatch safety")
struct BatchDispatchTests {
    @Test("Pre-dispatch batch failure reaches the caller")
    func keepsDeadline() async throws {
        let fixture = try makeBatchBridge()
        let bridge = fixture.bridge
        let scriptsDirectory = fixture.directory
        defer { try? FileManager.default.removeItem(at: scriptsDirectory) }
        let attempts = BatchAttemptCounter()

        do {
            try await bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal"),
            ]) { _ in
                _ = await attempts.next()
                throw AppleScriptBridgeError.dispatchDeadline(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            }
            Issue.record("Expected dispatchDeadline")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 1)
    }

    @Test("Ambiguous batch failure requires verification")
    func wrapsAmbiguousFailure() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal"),
            ]) { _ in
                throw AppleScriptBridgeError.timeout(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            }
            Issue.record("Expected batch verification failure")
        } catch let error as AppleScriptBatchVerificationError {
            #expect(error.updateCount == 1)
        } catch {
            Issue.record("Expected AppleScriptBatchVerificationError, got \(error)")
        }
    }

    @Test("Retry preserves an earlier ambiguous batch failure")
    func preservesAmbiguousFailure() async {
        let bridge = makeBridge()
        let attempts = BatchAttemptCounter()
        let retry = retryConfig()

        do {
            _ = try await bridge.retryAppleScriptOperation(
                scriptName: "batch_update_tracks",
                retry: retry
            ) {
                let attempt = await attempts.next()
                if attempt == 1 {
                    throw AppleScriptBridgeError.timeout(
                        scriptName: "batch_update_tracks",
                        duration: .seconds(1)
                    )
                }
                throw AppleScriptBridgeError.dispatchDeadline(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            }
            Issue.record("Expected retry failure")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected the earlier timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 2)
    }

    @Test("Retry budget preserves an all-pre-dispatch failure")
    func keepsDeadlineAfterRetryBudget() async {
        let bridge = makeBridge()
        let attempts = BatchAttemptCounter()
        var retry = retryConfig()
        retry.operationTimeoutSeconds = 0.02
        let deadline = AppleScriptBridgeError.dispatchDeadline(
            scriptName: "batch_update_tracks",
            duration: .seconds(1)
        )
        #expect(AppleScriptBridge.isRetryableAppleScriptError(deadline))

        do {
            _ = try await bridge.retryAppleScriptOperation(
                scriptName: "batch_update_tracks",
                retry: retry
            ) {
                _ = await attempts.next()
                try await Task.sleep(for: .milliseconds(50))
                throw deadline
            }
            Issue.record("Expected retry failure")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 1)
    }

    @Test("Retry budget preserves an earlier ambiguous failure")
    func preservesAmbiguousFailureAfterRetryBudget() async {
        let bridge = makeBridge()
        let attempts = BatchAttemptCounter()
        var retry = retryConfig()
        retry.maxRetries = 2
        retry.operationTimeoutSeconds = 0.25

        do {
            _ = try await bridge.retryAppleScriptOperation(
                scriptName: "batch_update_tracks",
                retry: retry
            ) {
                let attempt = await attempts.next()
                if attempt == 1 {
                    throw AppleScriptBridgeError.timeout(
                        scriptName: "batch_update_tracks",
                        duration: .seconds(1)
                    )
                }
                try await Task.sleep(for: .milliseconds(300))
                throw AppleScriptBridgeError.dispatchDeadline(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            }
            Issue.record("Expected retry failure")
        } catch let error as AppleScriptBridgeError {
            guard case let .timeout(_, duration) = error else {
                Issue.record("Expected the earlier timeout, got \(error)")
                return
            }
            #expect(duration == .seconds(1))
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 2)
    }

    private func makeBridge(scriptsDirectory: URL = FileManager.default.temporaryDirectory) -> AppleScriptBridge {
        let installer = ScriptInstaller(
            scriptsDirectory: scriptsDirectory,
            bundleScriptsDirectory: nil
        )
        return AppleScriptBridge(installer: installer)
    }

    private func makeBatchBridge() throws -> (bridge: AppleScriptBridge, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("batch_update_tracks.scpt"))
        return (makeBridge(scriptsDirectory: directory), directory)
    }

    private func retryConfig() -> AppleScriptRetry {
        var retry = AppleScriptRetry()
        retry.maxRetries = 1
        retry.baseDelaySeconds = 0
        retry.maxDelaySeconds = 0
        retry.jitterRange = 0
        return retry
    }
}

private actor BatchAttemptCounter {
    private var count = 0

    var value: Int {
        count
    }

    func next() -> Int {
        count += 1
        return count
    }
}
