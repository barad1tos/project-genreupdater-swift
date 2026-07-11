import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("AppleScriptBridge - rate and batch configuration")
struct AppleScriptConfigTests {
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

    @Test("Track ID batch sizes follow runtime configuration")
    func usesConfiguredBatches() async {
        let bridge = makeConfigBridge()
        var configuration = AppleScriptConfig()
        configuration.batchProcessing.idsBatchSize = 17
        configuration.batchProcessing.batchSize = 1700

        await bridge.updateConfiguration(configuration)

        #expect(await bridge.trackIDBatchSize == 17)
        #expect(await bridge.scanBatchSize == 1000)

        configuration.batchProcessing.idsBatchSize = 0
        configuration.batchProcessing.batchSize = 0
        await bridge.updateConfiguration(configuration)

        #expect(await bridge.trackIDBatchSize == 1)
        #expect(await bridge.scanBatchSize == 1)
    }

    @Test("Track ID fetch clamps invalid batch size before script execution")
    func clampsInvalidIDBatchSize() async {
        let bridge = makeConfigBridge()

        do {
            _ = try await bridge.fetchTracksByIDs(["AS-1"], batchSize: 0)
            Issue.record("Expected missing fetch script")
        } catch let error as AppleScriptBridgeError {
            guard case .scriptNotFound = error else {
                Issue.record("Expected scriptNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
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

    @Test("Batch update missing script error takes priority over argument validation")
    func batchUpdateMissingScriptErrorTakesPriorityOverArgumentValidation() async throws {
        let scriptsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleScriptBridgeMissingScript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptsDirectory) }

        let installer = ScriptInstaller(scriptsDirectory: scriptsDirectory, bundleScriptsDirectory: nil)
        let bridge = AppleScriptBridge(installer: installer)

        do {
            // Value contains a reserved separator that would make makeBatchUpdateArgument throw
            // if it ran before the script check. The script check must run first.
            try await bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal\(Track.fieldSeparator)Jazz"),
            ])
            Issue.record("Expected missing batch script to fail before AppleScript execution")
        } catch let error as AppleScriptBridgeError {
            guard case .scriptNotFound = error else {
                Issue.record("Expected scriptNotFound (checked before argument validation), got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
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

    @Test("Parsed track output error detail does not contain user metadata")
    func parsedTrackOutputErrorDetailDoesNotContainUserMetadata() {
        let secretName = "SECRET_TRACK_NAME"
        _ = String(Track.recordSeparator)
        let malformed = malformedAppleScriptTrackOutput(secretName, "artist", "album")

        do {
            _ = try AppleScriptBridge.parseTrackOutput(malformed)
            Issue.record("Expected AppleScriptBridgeError")
        } catch let error as AppleScriptBridgeError {
            guard case let .parseError(_, detail) = error else {
                Issue.record("Expected parseError, got \(error)")
                return
            }
            #expect(!detail.contains(secretName))
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Parsed track output error is still AppleScriptBridgeError")
    func parsedTrackOutputErrorIsStillAppleScriptBridgeError() {
        _ = String(Track.recordSeparator)
        let malformed = malformedAppleScriptTrackOutput("only", "three", "fields")

        #expect(throws: AppleScriptBridgeError.self) {
            _ = try AppleScriptBridge.parseTrackOutput(malformed)
        }
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

private func makeConfigBridge() -> AppleScriptBridge {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleScriptConfigTests-\(UUID().uuidString)")
    return AppleScriptBridge(
        installer: ScriptInstaller(scriptsDirectory: directory, bundleScriptsDirectory: nil)
    )
}
