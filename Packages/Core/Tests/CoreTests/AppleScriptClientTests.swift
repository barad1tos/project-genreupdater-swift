import Foundation
import Testing
@testable import Core

@Suite("AppleScriptClient — default fetch helpers")
struct AppleScriptClientTests {
    @Test("Default fetchTracks passes artist scope and parses AppleScript output")
    func defaultFetchTracksPassesArtistScopeAndParsesAppleScriptOutput() async throws {
        let output = appleScriptTrackOutput(
            id: "101",
            name: "Зимно",
            artist: "Паліндром",
            album: "Найліпші питання собі",
            year: "2024",
            releaseYear: "2024",
            status: "purchased"
        )
        let client = ScriptOutputClient(output: output)

        let tracks = try await client.fetchTracks(artist: "Паліндром", timeout: .seconds(3))

        let call = try #require(await client.calls.first)
        #expect(call.name == "fetch_tracks")
        #expect(call.arguments == ["Паліндром"])
        #expect(call.timeout == .seconds(3))
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == "101")
        #expect(tracks.first?.artist == "Паліндром")
        #expect(tracks.first?.year == 2024)
    }

    @Test("Default fetchTracks treats Music empty-library sentinel as empty")
    func defaultFetchTracksTreatsMusicEmptyLibrarySentinelAsEmpty() async throws {
        let client = ScriptOutputClient(output: "NO_TRACKS_FOUND")

        let tracks = try await client.fetchTracks()

        let call = try #require(await client.calls.first)
        #expect(call.name == "fetch_tracks")
        #expect(call.arguments.isEmpty)
        #expect(call.timeout == nil)
        #expect(tracks.isEmpty)
    }

    @Test("Default fetchTracks rejects malformed non-empty records")
    func defaultFetchTracksRejectsMalformedNonEmptyRecords() async {
        let output = [
            appleScriptTrackOutput(id: "101", name: "American Sleep"),
            appleScriptTrackOutput(id: "", name: "Missing ID"),
        ].joined(separator: String(Track.recordSeparator))
        let client = ScriptOutputClient(output: output)

        await #expect(throws: AppleScriptClientParseError.self) {
            _ = try await client.fetchTracks(artist: "Clutch")
        }
    }

    @Test("Default fetchAllTrackIDs runs lightweight ID script")
    func defaultFetchAllTrackIDsRunsLightweightIDScript() async throws {
        let client = ScriptOutputClient(output: " 10, 20,, 30, ")

        let trackIDs = try await client.fetchAllTrackIDs(timeout: .seconds(5))

        let call = try #require(await client.calls.first)
        #expect(call.name == "fetch_track_ids")
        #expect(call.arguments.isEmpty)
        #expect(call.timeout == .seconds(5))
        #expect(trackIDs == ["10", "20", "30"])
    }

    @Test("Default fetchTracksByIDs batches IDs and parses AppleScript output")
    func defaultFetchTracksByIDsBatchesIDsAndParsesAppleScriptOutput() async throws {
        let firstBatchOutput = appleScriptTrackOutput(id: "101", name: "American Sleep")
        let secondBatchOutput = appleScriptTrackOutput(
            id: "103",
            name: "Зимно",
            artist: "Паліндром",
            album: "Найліпші питання собі",
            year: "2024",
            releaseYear: "2024",
            status: "purchased"
        )
        let client = ScriptOutputClient(outputs: [
            firstBatchOutput,
            "NO_TRACKS_FOUND",
            secondBatchOutput,
        ])

        let tracks = try await client.fetchTracksByIDs(
            ["101", "102", "103"],
            batchSize: 1,
            timeout: .seconds(7)
        )

        let calls = await client.calls
        #expect(calls.map(\.name) == ["fetch_tracks_by_ids", "fetch_tracks_by_ids", "fetch_tracks_by_ids"])
        #expect(calls.map(\.arguments) == [["101"], ["102"], ["103"]])
        #expect(calls.map(\.timeout) == [.seconds(7), .seconds(7), .seconds(7)])
        #expect(tracks.map(\.id) == ["101", "103"])
        #expect(tracks.first?.year == 1999)
        #expect(tracks.first?.releaseYear == 2001)
        #expect(tracks.last?.artist == "Паліндром")
    }

    @Test("Parse error detail does not contain user metadata")
    func parseErrorDetailDoesNotContainUserMetadata() async {
        let secretName = "SECRET_TRACK_NAME"
        let malformedRecord = [secretName, "artist", "album"]
            .joined(separator: String(Track.fieldSeparator))
        let output = [malformedRecord].joined(separator: String(Track.recordSeparator))
        let client = ScriptOutputClient(output: output)

        do {
            _ = try await client.fetchTracks(artist: "Test")
            Issue.record("Expected AppleScriptClientParseError")
        } catch let error as AppleScriptClientParseError {
            #expect(error is AppleScriptClientParseError)
            #expect(!error.detail.contains(secretName))
        } catch {
            Issue.record("Expected AppleScriptClientParseError, got \(error)")
        }
    }

    @Test("Parse error detail reports accurate field count with empty fields")
    func parseErrorDetailReportsAccurateFieldCountWithEmptyFields() async {
        // 12-field record with empty ID and empty placeholder fields — rejected by
        // fromAppleScriptOutput for missing ID, but field count must reflect all
        // 12 fields (omittingEmptySubsequences: false matches parser semantics).
        let malformedRecord = appleScriptTrackOutput(id: "", name: "Missing ID")
        let output = [malformedRecord].joined(separator: String(Track.recordSeparator))
        let client = ScriptOutputClient(output: output)

        do {
            _ = try await client.fetchTracks(artist: "Test")
            Issue.record("Expected AppleScriptClientParseError")
        } catch let error as AppleScriptClientParseError {
            #expect(error.detail.contains("got 12"))
        } catch {
            Issue.record("Expected AppleScriptClientParseError, got \(error)")
        }
    }

    @Test("Default fetchTracksByIDs rejects malformed non-empty records")
    func defaultFetchTracksByIDsRejectsMalformedNonEmptyRecords() async {
        let output = [
            appleScriptTrackOutput(id: "101", name: "American Sleep"),
            appleScriptTrackOutput(id: "", name: "Missing ID"),
        ].joined(separator: String(Track.recordSeparator))
        let client = ScriptOutputClient(output: output)

        await #expect(throws: AppleScriptClientParseError.self) {
            _ = try await client.fetchTracksByIDs(["101", "102"], batchSize: 2)
        }
    }

    @Test("Default fetchTracksByIDs handles empty, exact, and overflow batches")
    func defaultFetchTracksByIDsHandlesEmptyExactAndOverflowBatches() async throws {
        let emptyClient = ScriptOutputClient(output: nil)

        let emptyTracks = try await emptyClient.fetchTracksByIDs(
            [],
            batchSize: 2,
            timeout: .seconds(7)
        )

        #expect(emptyTracks.isEmpty)
        #expect(await emptyClient.calls.isEmpty)

        let client = ScriptOutputClient(outputs: [
            appleScriptTrackOutput(id: "101", name: "American Sleep"),
            appleScriptTrackOutput(id: "103", name: "Careful With That Mic..."),
            appleScriptTrackOutput(id: "105", name: "Drink to the Dead"),
        ])

        let tracks = try await client.fetchTracksByIDs(
            ["101", "102", "103", "104", "105"],
            batchSize: 2,
            timeout: .seconds(7)
        )

        let calls = await client.calls
        #expect(calls.map(\.name) == ["fetch_tracks_by_ids", "fetch_tracks_by_ids", "fetch_tracks_by_ids"])
        #expect(calls.map(\.arguments) == [["101,102"], ["103,104"], ["105"]])
        #expect(calls.map(\.timeout) == [.seconds(7), .seconds(7), .seconds(7)])
        #expect(tracks.map(\.id) == ["101", "103", "105"])
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
        "Rock", "", "", status, year, releaseYear, "",
    ].joined(separator: String(Track.fieldSeparator))
}

private actor ScriptOutputClient: AppleScriptClient {
    private var outputs: [String?]
    private(set) var calls: [ScriptCall] = []

    init(output: String?) {
        outputs = [output]
    }

    init(outputs: [String?]) {
        self.outputs = outputs
    }

    func initialize() async throws {
        // No setup needed: these tests exercise the protocol-default fetch helper.
    }

    func runScript(
        name: String,
        arguments: [String],
        timeout: Duration?
    ) async throws -> String? {
        calls.append(ScriptCall(
            name: name,
            arguments: arguments,
            timeout: timeout
        ))
        guard !outputs.isEmpty else { return nil }
        return outputs.removeFirst()
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        throw ScriptOutputClientError.unsupportedWrite
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
        throw ScriptOutputClientError.unsupportedWrite
    }
}

private enum ScriptOutputClientError: Error {
    case unsupportedWrite
}

private struct ScriptCall {
    let name: String
    let arguments: [String]
    let timeout: Duration?
}
