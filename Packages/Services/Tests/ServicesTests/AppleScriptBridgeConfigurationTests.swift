import Carbon.OpenScripting
import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("AppleScriptBridge - retry and rate configuration")
struct AppleScriptBridgeConfigurationTests {
    @Test("Concurrency limit clamps to at least one")
    func concurrencyLimitClampsToAtLeastOne() {
        #expect(AppleScriptBridge.normalizedConcurrencyLimit(2) == 2)
        #expect(AppleScriptBridge.normalizedConcurrencyLimit(0) == 1)
        #expect(AppleScriptBridge.normalizedConcurrencyLimit(-4) == 1)
    }

    @Test("Retry classifier retries transient AppleScript failures")
    func retryClassifierRetriesTransientAppleScriptFailures() {
        let timeout = AppleScriptBridgeError.timeout(scriptName: "fetch_tracks", duration: .seconds(1))
        let execution = AppleScriptBridgeError.executionFailed(scriptName: "fetch_tracks", detail: "Music busy")
        let musicNotRunning = AppleScriptBridgeError.musicAppNotRunning

        #expect(AppleScriptBridge.isRetryableAppleScriptError(timeout))
        #expect(AppleScriptBridge.isRetryableAppleScriptError(execution))
        #expect(AppleScriptBridge.isRetryableAppleScriptError(musicNotRunning))
    }

    @Test("Retry classifier rejects permanent AppleScript failures")
    func retryClassifierRejectsPermanentAppleScriptFailures() {
        let missing = AppleScriptBridgeError.scriptNotFound(
            name: "missing",
            searchPath: URL(fileURLWithPath: "/tmp")
        )
        let parseError = AppleScriptBridgeError.parseError(scriptName: "fetch_tracks", detail: "bad output")
        let notInstalled = AppleScriptBridgeError.scriptsNotInstalled

        #expect(!AppleScriptBridge.isRetryableAppleScriptError(missing))
        #expect(!AppleScriptBridge.isRetryableAppleScriptError(parseError))
        #expect(!AppleScriptBridge.isRetryableAppleScriptError(notInstalled))
    }

    @Test("Retry delay applies deterministic bounded jitter")
    func retryDelayAppliesDeterministicBoundedJitter() {
        let first = AppleScriptBridge.retryDelaySeconds(
            afterFailureAt: 0,
            baseDelaySeconds: 10,
            jitterRange: 0.2
        )
        let noJitter = AppleScriptBridge.retryDelaySeconds(
            afterFailureAt: 0,
            baseDelaySeconds: 10,
            jitterRange: 0
        )

        #expect(first >= 8)
        #expect(first <= 12)
        #expect(noJitter == 10)
    }

    @Test("Disabled rate limit does not create limiter")
    func disabledRateLimitDoesNotCreateLimiter() {
        var configuration = AppleScriptRateLimit()
        configuration.enabled = false

        #expect(AppleScriptBridge.makeRateLimiter(configuration: configuration) == nil)
    }

    @Test("Enabled rate limit creates limiter")
    func enabledRateLimitCreatesLimiter() {
        var configuration = AppleScriptRateLimit()
        configuration.enabled = true
        configuration.requestsPerWindow = 10
        configuration.windowSizeSeconds = 1

        #expect(AppleScriptBridge.makeRateLimiter(configuration: configuration) != nil)
    }

    @Test("AppleScript argv event launches script with direct arguments")
    func appleScriptArgvEventLaunchesScriptWithDirectArguments() throws {
        let event = try #require(AppleScriptBridge.makeRunAppleEvent(arguments: ["In Flames"]))
        let arguments = try #require(event.paramDescriptor(forKeyword: keyDirectObject))

        #expect(event.eventClass == AEEventClass(kCoreEventClass))
        #expect(event.eventID == AEEventID(kAEOpenApplication))
        #expect(arguments.numberOfItems == 1)
        #expect(arguments.atIndex(1)?.stringValue == "In Flames")
    }

    @Test("Track ID parser preserves empty library sentinel and rejects AppleScript errors")
    func trackIDParserPreservesEmptyLibraryAndRejectsErrors() throws {
        #expect(try AppleScriptBridge.parseTrackIDOutput(" 10, 20,, 30, ") == ["10", "20", "30"])
        #expect(try AppleScriptBridge.parseTrackIDOutput("NO_TRACKS_FOUND").isEmpty)
        #expect(try AppleScriptBridge.parseTrackIDOutput("").isEmpty)
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.parseTrackIDOutput("ERROR:Music failed")
        }
    }

    @Test("Single update output accepts script success and no-change responses")
    func singleUpdateOutputAcceptsSuccessAndNoChangeResponses() throws {
        try AppleScriptBridge.validateUpdatePropertyOutput(
            "Success: Updated track 10 genre from 'Rock' to 'Metal'",
            trackID: "10",
            property: "genre"
        )
        try AppleScriptBridge.validateUpdatePropertyOutput(
            "No Change: Track 10 genre already set to Metal",
            trackID: "10",
            property: "genre"
        )
    }

    @Test("Single update output rejects errors, empty response, and unknown text")
    func singleUpdateOutputRejectsFailures() throws {
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateUpdatePropertyOutput(
                "Error: Track 10 not found",
                trackID: "10",
                property: "genre"
            )
        }
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateUpdatePropertyOutput(nil, trackID: "10", property: "genre")
        }
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateUpdatePropertyOutput(
                "Updated track 10",
                trackID: "10",
                property: "genre"
            )
        }
    }

    @Test("Batch update output rejects per-track AppleScript failures")
    func batchUpdateOutputRejectsPerTrackFailures() throws {
        try AppleScriptBridge.validateBatchUpdateOutput(
            "Success: Batch update process completed.",
            updateCount: 2
        )
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateBatchUpdateOutput(
                "Error updating track ID T1: Music failed\nSuccess: Batch update process completed.",
                updateCount: 2
            )
        }
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateBatchUpdateOutput(
                "Year 1800 out of range for track T1\nSuccess: Batch update process completed.",
                updateCount: 2
            )
        }
    }

    @Test("Track output parser preserves valid records and skips malformed records")
    func trackOutputParserPreservesValidRecordsAndSkipsMalformedRecords() throws {
        let fieldSeparator = String(Track.fieldSeparator)
        let recordSeparator = String(Track.recordSeparator)
        let validFirst = [
            "101", "American Sleep", "Clutch", "Clutch", "Pure Rock Fury",
            "Rock", "2024-02-21 13:45:00", "2024-03-01 10:00:00",
            "matched", "1999", "2001", "",
        ].joined(separator: fieldSeparator)
        let malformed = ["broken", "record", "only"].joined(separator: fieldSeparator)
        let validSecond = [
            "102", "Паліндром", "Паліндром", "", "Найліпші питання собі",
            "", "", "", "purchased", "2024", "2024", "",
        ].joined(separator: fieldSeparator)

        let tracks = AppleScriptBridge.parseTrackOutput(
            [validFirst, malformed, validSecond].joined(separator: recordSeparator)
        )

        #expect(tracks.map(\.id) == ["101", "102"])
        #expect(tracks.first?.name == "American Sleep")
        #expect(tracks.first?.year == 1999)
        #expect(tracks.first?.releaseYear == 2001)
        let cyrillicTrack = try #require(tracks.last)
        #expect(cyrillicTrack.name == "Паліндром")
        #expect(cyrillicTrack.artist == "Паліндром")
        #expect(cyrillicTrack.year == 2024)
    }

    @Test("Retry loop retries transient failures until success")
    func retryLoopRetriesTransientFailuresUntilSuccess() async throws {
        let bridge = makeRetryBridge()
        let probe = RetryProbe(transientFailuresBeforeSuccess: 2)

        let result = try await bridge.retryAppleScriptOperation(
            scriptName: "fetch_tracks",
            retry: retryWithoutDelay()
        ) {
            try await probe.transientThenSuccess()
        }

        #expect(result == "ok")
        #expect(await probe.attempts == 3)
    }

    @Test("Retry loop does not retry permanent failures")
    func retryLoopDoesNotRetryPermanentFailures() async throws {
        let bridge = makeRetryBridge()
        let probe = RetryProbe(permanentFailure: AppleScriptBridgeError.parseError(
            scriptName: "fetch_tracks",
            detail: "bad output"
        ))

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await bridge.retryAppleScriptOperation(
                scriptName: "fetch_tracks",
                retry: retryWithoutDelay()
            ) {
                try await probe.alwaysFailPermanently()
            }
        }
        #expect(await probe.attempts == 1)
    }
}

private func makeRetryBridge() -> AppleScriptBridge {
    let scriptsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleScriptBridgeRetryTests-\(UUID().uuidString)")
    let installer = ScriptInstaller(
        scriptsDirectory: scriptsDirectory,
        bundleScriptsDirectory: nil
    )
    return AppleScriptBridge(installer: installer)
}

private func retryWithoutDelay() -> AppleScriptRetry {
    var retry = AppleScriptRetry()
    retry.maxRetries = 2
    retry.baseDelaySeconds = 0
    retry.maxDelaySeconds = 0
    retry.jitterRange = 0
    retry.operationTimeoutSeconds = 30
    return retry
}

private actor RetryProbe {
    private var remainingTransientFailures: Int
    private let permanentFailure: AppleScriptBridgeError?
    private var attemptCount = 0

    init(transientFailuresBeforeSuccess: Int) {
        remainingTransientFailures = transientFailuresBeforeSuccess
        permanentFailure = nil
    }

    init(permanentFailure: AppleScriptBridgeError) {
        remainingTransientFailures = 0
        self.permanentFailure = permanentFailure
    }

    var attempts: Int {
        attemptCount
    }

    func transientThenSuccess() throws -> String {
        attemptCount += 1
        if remainingTransientFailures > 0 {
            remainingTransientFailures -= 1
            throw AppleScriptBridgeError.timeout(scriptName: "fetch_tracks", duration: .seconds(1))
        }
        return "ok"
    }

    func alwaysFailPermanently() throws -> String {
        attemptCount += 1
        throw permanentFailure ?? AppleScriptBridgeError.parseError(
            scriptName: "fetch_tracks",
            detail: "bad output"
        )
    }
}
