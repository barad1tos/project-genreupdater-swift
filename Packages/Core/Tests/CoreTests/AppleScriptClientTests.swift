import Foundation
import Testing
@testable import Core

@Suite("AppleScriptClient — default fetch helpers")
struct AppleScriptClientTests {
    @Test("Default fetchTracks passes artist scope and parses AppleScript output")
    func defaultFetchTracksPassesArtistScopeAndParsesAppleScriptOutput() async throws {
        let fieldSeparator = String(Track.fieldSeparator)
        let output = [
            "101", "Зимно", "Паліндром", "Паліндром", "Найліпші питання собі",
            "Rap", "", "", "purchased", "2024", "2024", "",
        ].joined(separator: fieldSeparator)
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
        #expect(call.arguments == [""])
        #expect(call.timeout == nil)
        #expect(tracks.isEmpty)
    }
}

private actor ScriptOutputClient: AppleScriptClient {
    private let output: String?
    private(set) var calls: [ScriptCall] = []

    init(output: String?) {
        self.output = output
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
        return output
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws {
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
