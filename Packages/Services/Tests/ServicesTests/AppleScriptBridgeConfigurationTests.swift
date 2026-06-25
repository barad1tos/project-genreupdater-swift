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
        let changed = try AppleScriptBridge.validateUpdatePropertyOutput(
            "Success: Updated track 10 genre from 'Rock' to 'Metal'",
            trackID: "10",
            property: "genre"
        )
        let noChange = try AppleScriptBridge.validateUpdatePropertyOutput(
            "No Change: Track 10 genre already set to Metal",
            trackID: "10",
            property: "genre"
        )

        #expect(changed == .changed)
        #expect(noChange == .noChange)
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

    @Test("Batch update output requires explicit script success marker")
    func batchUpdateOutputRequiresExplicitScriptSuccessMarker() throws {
        try AppleScriptBridge.validateBatchUpdateOutput(
            "Success: Batch update process completed.",
            updateCount: 2
        )
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateBatchUpdateOutput(nil, updateCount: 2)
        }
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateBatchUpdateOutput("   ", updateCount: 2)
        }
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateBatchUpdateOutput("Updated 2 tracks", updateCount: 2)
        }
        #expect(throws: AppleScriptBridgeError.self) {
            try AppleScriptBridge.validateBatchUpdateOutput("Error: Track T1 not found", updateCount: 2)
        }
    }

    @Test("Batch update missing script remains a pre-run bridge error")
    func batchUpdateMissingScriptRemainsPreRunBridgeError() async throws {
        let scriptsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleScriptBridgeMissingScript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptsDirectory) }

        let installer = ScriptInstaller(scriptsDirectory: scriptsDirectory, bundleScriptsDirectory: nil)
        let bridge = AppleScriptBridge(installer: installer)

        do {
            try await bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Stoner Rock"),
            ])
            Issue.record("Expected missing batch script to fail before AppleScript execution")
        } catch let error as AppleScriptBridgeError {
            guard case .scriptNotFound = error else {
                Issue.record("Expected scriptNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Batch update verification rejects stale or missing refreshed tracks")
    func batchUpdateVerificationRejectsStaleOrMissingRefreshedTracks() throws {
        let updates = [
            (trackID: "101", property: "genre", value: "Stoner Rock"),
            (trackID: "102", property: "year", value: "2001"),
        ]
        let staleTracks = [
            Track(id: "101", name: "American Sleep", artist: "Clutch", album: "Pure Rock Fury", genre: "Rock"),
            Track(id: "102", name: "Pure Rock Fury", artist: "Clutch", album: "Pure Rock Fury", year: 2001),
        ]
        let missingTracks = [
            Track(id: "101", name: "American Sleep", artist: "Clutch", album: "Pure Rock Fury", genre: "Stoner Rock"),
        ]
        let duplicateTracks = [
            Track(id: "101", name: "American Sleep", artist: "Clutch", album: "Pure Rock Fury", genre: "Stoner Rock"),
            Track(id: "101", name: "American Sleep", artist: "Clutch", album: "Pure Rock Fury", genre: "Rock"),
            Track(id: "102", name: "Pure Rock Fury", artist: "Clutch", album: "Pure Rock Fury", year: 2001),
        ]

        #expect(throws: AppleScriptBatchVerificationError.self) {
            try AppleScriptBridge.verifyBatchUpdateValues(updates, in: staleTracks)
        }
        #expect(throws: AppleScriptBatchVerificationError.self) {
            try AppleScriptBridge.verifyBatchUpdateValues(updates, in: missingTracks)
        }
        try AppleScriptBridge.verifyBatchUpdateValues(updates, in: duplicateTracks)
    }

    @Test("Batch update verification maps album artist property")
    func batchUpdateVerificationMapsAlbumArtistProperty() throws {
        let updates = [
            (trackID: "101", property: "album_artist", value: "Clutch"),
        ]
        let refreshedTracks = [
            Track(
                id: "101",
                name: "American Sleep",
                artist: "Clutch",
                album: "Pure Rock Fury",
                albumArtist: "Clutch"
            ),
        ]
        let staleTracks = [
            Track(
                id: "101",
                name: "American Sleep",
                artist: "Clutch",
                album: "Pure Rock Fury",
                albumArtist: nil
            ),
        ]

        try AppleScriptBridge.verifyBatchUpdateValues(updates, in: refreshedTracks)
        #expect(throws: AppleScriptBatchVerificationError.self) {
            try AppleScriptBridge.verifyBatchUpdateValues(updates, in: staleTracks)
        }
    }

    @Test("Batch update argv preserves direct metadata payloads")
    func batchUpdateArgvPreservesDirectMetadataPayloads() throws {
        let value = #"Паліндром / Альбом, Частина & "Live"\Raw (EP) [Single]"#
        let argument = try AppleScriptBridge.makeBatchUpdateArgument([
            (trackID: #"T"1"#, property: "genre", value: value),
        ])
        let fields = argument
            .split(separator: Track.fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)

        #expect(fields == [#"T"1"#, "genre", value])
    }

    @Test("Batch update argv rejects reserved separators and unknown properties")
    func batchUpdateArgvRejectsReservedSeparatorsAndUnknownProperties() {
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.makeBatchUpdateArgument([
                (trackID: "T1", property: "genre", value: "Metal\(Track.fieldSeparator)Jazz"),
            ])
        }
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.makeBatchUpdateArgument([
                (trackID: "T1\(Track.recordSeparator)", property: "genre", value: "Metal"),
            ])
        }
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.makeBatchUpdateArgument([
                (trackID: "T1", property: "genre;stop", value: "Metal"),
            ])
        }
    }

    @Test("Track output parser preserves valid records and skips empty records")
    func trackOutputParserPreservesValidRecordsAndSkipsEmptyRecords() throws {
        let recordSeparator = String(Track.recordSeparator)
        let validFirst = appleScriptTrackOutput(id: "101", name: "American Sleep")
        let duplicateIdentity = appleScriptTrackOutput(id: "103", name: "American Sleep")
        let validSecond = appleScriptTrackOutput(
            id: "102",
            name: "Паліндром",
            artist: "Паліндром",
            album: "Найліпші питання собі",
            year: "2024",
            releaseYear: "2024",
            status: "purchased"
        )

        let tracks = try AppleScriptBridge.parseTrackOutput(
            ["", validFirst, "", duplicateIdentity, validSecond, ""]
                .joined(separator: recordSeparator)
        )

        #expect(tracks.map(\.id) == ["101", "103", "102"])
        #expect(tracks.first?.name == "American Sleep")
        #expect(tracks.first?.year == 1999)
        #expect(tracks.first?.releaseYear == 2001)
        let duplicateTrack = try #require(tracks.first { $0.id == "103" })
        #expect(duplicateTrack.name == "American Sleep")
        #expect(duplicateTrack.artist == "Clutch")
        #expect(duplicateTrack.album == "Pure Rock Fury")
        let cyrillicTrack = try #require(tracks.last)
        #expect(cyrillicTrack.name == "Паліндром")
        #expect(cyrillicTrack.artist == "Паліндром")
        #expect(cyrillicTrack.year == 2024)
    }

    @Test("Track output parser rejects malformed non-empty records")
    func trackOutputParserRejectsMalformedNonEmptyRecords() {
        let recordSeparator = String(Track.recordSeparator)
        let valid = appleScriptTrackOutput(id: "101", name: "American Sleep")
        let malformed = malformedAppleScriptTrackOutput("broken", "record", "only")
        let missingID = appleScriptTrackOutput(id: "", name: "Ghost Track")

        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.parseTrackOutput([valid, malformed].joined(separator: recordSeparator))
        }
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.parseTrackOutput([valid, missingID].joined(separator: recordSeparator))
        }
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

private func appleScriptTrackOutput(
    id: String,
    name: String,
    artist: String = "Clutch",
    album: String = "Pure Rock Fury",
    year: String = "1999",
    releaseYear: String = "2001",
    status: String = "matched"
) -> String {
    [
        id, name, artist, artist, album,
        "Rock", "2024-02-21 13:45:00", "2024-03-01 10:00:00",
        status, year, releaseYear, "",
    ].joined(separator: String(Track.fieldSeparator))
}

private func malformedAppleScriptTrackOutput(_ fields: String...) -> String {
    fields.joined(separator: String(Track.fieldSeparator))
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
