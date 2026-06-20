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

    @Test("Track ID parser ignores blank IDs and AppleScript error output")
    func trackIDParserIgnoresBlankIDsAndErrors() {
        #expect(AppleScriptBridge.parseTrackIDOutput(" 10, 20,, 30, ") == ["10", "20", "30"])
        #expect(AppleScriptBridge.parseTrackIDOutput("ERROR:Music failed").isEmpty)
        #expect(AppleScriptBridge.parseTrackIDOutput("NO_TRACKS_FOUND").isEmpty)
        #expect(AppleScriptBridge.parseTrackIDOutput("").isEmpty)
    }
}
