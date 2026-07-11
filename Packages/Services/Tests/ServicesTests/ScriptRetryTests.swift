import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("AppleScript retry policy")
struct ScriptRetryTests {
    @Test("Only known read scripts are retryable")
    func classifiesIntent() {
        #expect(AppleScriptBridge.intent(forScript: "fetch_track_ids") == .read)
        #expect(AppleScriptBridge.intent(forScript: "fetch_tracks") == .read)
        #expect(AppleScriptBridge.intent(forScript: "fetch_tracks_by_ids") == .read)
        #expect(AppleScriptBridge.intent(forScript: "update_property") == .mutation)
        #expect(AppleScriptBridge.intent(forScript: "batch_update_tracks") == .mutation)
        #expect(AppleScriptBridge.intent(forScript: "unknown_script") == .mutation)
    }

    @Test("Every bundled script has an explicit intent")
    func classifiesBundledScripts() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        // File -> ServicesTests -> Tests -> Services -> Packages -> repository root.
        let repositoryRoot = (0 ..< 5).reduce(testFile) { url, _ in
            url.deletingLastPathComponent()
        }
        let scriptsDirectory = repositoryRoot.appendingPathComponent("Resources/Scripts")
        let bundledScripts = try Set(
            FileManager.default.contentsOfDirectory(at: scriptsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "applescript" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )

        #expect(bundledScripts == Set(AppleScriptBridge.scriptIntents.keys))
    }

    @Test("Retry classifier separates transient and permanent failures")
    func classifiesFailures() {
        let deadline = AppleScriptBridgeError.dispatchDeadline(
            scriptName: "fetch_tracks",
            duration: .seconds(1)
        )
        let timeout = AppleScriptBridgeError.timeout(scriptName: "fetch_tracks", duration: .seconds(1))
        let execution = AppleScriptBridgeError.executionFailed(scriptName: "fetch_tracks", detail: "Music busy")
        let notRunning = AppleScriptBridgeError.musicAppNotRunning
        let parseError = AppleScriptBridgeError.parseError(scriptName: "fetch_tracks", detail: "bad output")
        let missing = AppleScriptBridgeError.scriptNotFound(
            name: "fetch_tracks",
            searchPath: FileManager.default.temporaryDirectory
        )
        let notInstalled = AppleScriptBridgeError.scriptsNotInstalled

        #expect(AppleScriptBridge.isRetryable(deadline))
        #expect(AppleScriptBridge.isRetryable(timeout))
        #expect(AppleScriptBridge.isRetryable(execution))
        #expect(AppleScriptBridge.isRetryable(notRunning))
        #expect(!AppleScriptBridge.isRetryable(parseError))
        #expect(!AppleScriptBridge.isRetryable(missing))
        #expect(!AppleScriptBridge.isRetryable(notInstalled))
    }

    @Test("Retry delay applies deterministic bounded jitter")
    func boundsJitter() {
        let jittered = AppleScriptBridge.retryDelay(attempt: 0, baseSeconds: 10, jitter: 0.2)
        let exact = AppleScriptBridge.retryDelay(attempt: 0, baseSeconds: 10, jitter: 0)

        #expect(jittered >= 8)
        #expect(jittered <= 12)
        #expect(exact == 10)
    }

    @Test("Transient read failures retry until success")
    func retriesTransientReads() async throws {
        let bridge = makeBridge()
        let probe = RetryProbe(failures: 2)

        let result = try await bridge.executeByIntent(
            scriptName: "fetch_tracks",
            retry: retryPolicy(),
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        ) { _ in
            try await probe.run()
        }

        #expect(result == "ok")
        #expect(await probe.attempts == 3)
    }

    @Test("Timeout reads retry when caller budget remains")
    func retriesTimeoutReads() async throws {
        let bridge = makeBridge()
        let probe = RetryProbe(
            failures: 1,
            error: .timeout(scriptName: "fetch_tracks", duration: .milliseconds(10))
        )

        let result = try await bridge.executeByIntent(
            scriptName: "fetch_tracks",
            retry: retryPolicy(),
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        ) { _ in
            try await probe.run()
        }

        #expect(result == "ok")
        #expect(await probe.attempts == 2)
    }

    @Test("Mutations and unknown scripts execute once")
    func executesMutationsOnce() async {
        for scriptName in ["update_property", "batch_update_tracks", "unknown_script"] {
            let bridge = makeBridge()
            let probe = RetryProbe(failures: 2)

            await #expect(throws: AppleScriptBridgeError.self) {
                _ = try await bridge.executeByIntent(
                    scriptName: scriptName,
                    retry: retryPolicy(),
                    deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                    timeout: .seconds(1)
                ) { _ in
                    try await probe.run()
                }
            }
            #expect(await probe.attempts == 1)
        }
    }

    @Test("Permanent read failures are not retried")
    func rejectsPermanentFailures() async {
        let bridge = makeBridge()
        let probe = RetryProbe(
            failures: 2,
            error: AppleScriptBridgeError.parseError(scriptName: "fetch_tracks", detail: "bad output")
        )

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await bridge.retryRead(
                scriptName: "fetch_tracks",
                retry: retryPolicy(),
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            ) { _ in
                try await probe.run()
            }
        }

        #expect(await probe.attempts == 1)
    }
}

private func makeBridge() -> AppleScriptBridge {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScriptRetryTests-\(UUID().uuidString)")
    return AppleScriptBridge(
        installer: ScriptInstaller(scriptsDirectory: directory, bundleScriptsDirectory: nil)
    )
}

private func retryPolicy() -> AppleScriptRetry {
    var retry = AppleScriptRetry()
    retry.maxRetries = 2
    retry.baseDelaySeconds = 0
    retry.maxDelaySeconds = 0
    retry.jitterRange = 0
    retry.operationTimeoutSeconds = 30
    return retry
}

private actor RetryProbe {
    private var failures: Int
    private let error: AppleScriptBridgeError
    private(set) var attempts = 0

    init(
        failures: Int,
        error: AppleScriptBridgeError = .executionFailed(scriptName: "fetch_tracks", detail: "Music busy")
    ) {
        self.failures = failures
        self.error = error
    }

    func run() throws -> String {
        attempts += 1
        guard failures > 0 else { return "ok" }
        failures -= 1
        throw error
    }
}
