import Core
import Foundation
import Testing
@testable import Services

@Suite("Library identity snapshot")
struct IdentitySnapshotTests {
    private let columnSeparator = String(UnicodeScalar(28))
    private let itemSeparator = String(UnicodeScalar(29))

    @Test("Decodes and deterministically sorts a complete columnar snapshot")
    func decodesCompleteSnapshot() throws {
        let output = try wire(
            count: 3,
            generation: "G1",
            ids: ["20", "10", "30"],
            artists: ["Second", "First", "Third"],
            albumArtists: ["", "Various Artists", nil]
        )

        let snapshot = try LibraryIdentitySnapshot.decode(output)

        #expect(snapshot.census.totalCount == 3)
        #expect(snapshot.census.generation.rawValue == "G1")
        #expect(snapshot.census.ids.map(\.rawValue) == ["10", "20", "30"])
        #expect(snapshot.rows.map(\.databaseID.rawValue) == ["10", "20", "30"])
        #expect(snapshot.rows.map(\.artist) == [.value("First"), .value("Second"), .value("Third")])
        #expect(snapshot.rows.map(\.albumArtist) == [.value("Various Artists"), .absent, .absent])
    }

    @Test("Accepts a stable empty snapshot")
    func acceptsEmptySnapshot() throws {
        let snapshot = try LibraryIdentitySnapshot.decode(
            ["IDENTITY", "0", "G1", "", "[]", "[]"].joined(separator: columnSeparator)
        )

        #expect(snapshot.census.totalCount == 0)
        #expect(snapshot.census.ids.isEmpty)
        #expect(snapshot.rows.isEmpty)
    }

    @Test("Preserves an ERROR prefix inside artist metadata")
    func preservesErrorTextInMetadata() throws {
        let snapshot = try LibraryIdentitySnapshot.decode(wire(
            count: 1,
            generation: "G1",
            ids: ["10"],
            artists: ["ERROR: Artist"],
            albumArtists: [""]
        ))

        #expect(snapshot.rows.first?.artist == .value("ERROR: Artist"))
    }

    @Test("Distinguishes absent identity from literal missing value")
    func distinguishesAbsentFromLiteralMissingValue() throws {
        let snapshot = try LibraryIdentitySnapshot.decode(wire(
            count: 2,
            generation: "G1",
            ids: ["10", "20"],
            artists: [nil, "Missing Value"],
            albumArtists: ["MISSING VALUE", nil]
        ))

        #expect(snapshot.rows[0].artist == .absent)
        #expect(snapshot.rows[0].albumArtist == .value("MISSING VALUE"))
        #expect(snapshot.rows[1].artist == .value("Missing Value"))
        #expect(snapshot.rows[1].albumArtist == .absent)
    }

    @Test("Rejects malformed or incomplete snapshot envelopes", arguments: [
        "",
        "WRONG",
        "IDENTITY\u{1C}-1\u{1C}G1\u{1C}\u{1C}\u{1C}",
        "IDENTITY\u{1C}1\u{1C}\u{1C}10\u{1C}Artist\u{1C}",
        "IDENTITY\u{1C}2\u{1C}G1\u{1C}10\u{1C}Artist\u{1C}",
    ])
    func rejectsMalformedEnvelope(_ output: String) {
        expectParseError(output)
    }

    @Test("Rejects invalid and duplicate database IDs", arguments: [
        "IDENTITY\u{1C}1\u{1C}G1\u{1C}invalid\u{1C}Artist\u{1C}",
        "IDENTITY\u{1C}2\u{1C}G1\u{1C}10\u{1D}10\u{1C}First\u{1D}Second\u{1C}\u{1D}",
    ])
    func rejectsInvalidIdentity(_ output: String) {
        do {
            _ = try LibraryIdentitySnapshot.decode(output)
            Issue.record("Expected invalid identity snapshot to be rejected")
        } catch {
            // Any decoding failure is sufficient for this malformed-input boundary.
        }
    }

    @Test("Maps producer failures to bridge errors")
    func mapsProducerFailures() {
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try LibraryIdentitySnapshot.decode("ERROR:Music is unavailable")
        }
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try LibraryIdentitySnapshot.decode("RETRY:GENERATION")
        }
    }

    private func wire(
        count: Int,
        generation: String,
        ids: [String],
        artists: [String?],
        albumArtists: [String?]
    ) throws -> String {
        try [
            "IDENTITY",
            String(count),
            generation,
            ids.joined(separator: itemSeparator),
            jsonColumn(artists),
            jsonColumn(albumArtists),
        ].joined(separator: columnSeparator)
    }

    private func jsonColumn(_ values: [String?]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FixtureError.invalidUTF8
        }
        return text
    }

    private func expectParseError(_ output: String) {
        do {
            _ = try LibraryIdentitySnapshot.decode(output)
            Issue.record("Expected malformed identity snapshot to be rejected")
        } catch let error as AppleScriptBridgeError {
            guard case let .parseError(scriptName, _) = error else {
                Issue.record("Expected parseError, got \(error)")
                return
            }
            #expect(scriptName == "fetch_library_identity")
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    private enum FixtureError: Error {
        case invalidUTF8
    }
}
