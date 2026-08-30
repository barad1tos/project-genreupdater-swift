import Core
import Testing
@testable import Services

@Suite("Library metadata snapshot")
struct MetadataSnapshotTests {
    private let columnSeparator = String(UnicodeScalar(28))
    private let itemSeparator = String(UnicodeScalar(29))

    @Test("Decodes complete raw metadata with row-compatible normalization")
    func decodesCompleteMetadata() throws {
        let output = wire(
            count: 2,
            generation: "G1",
            columns: [
                ["20", "10"],
                ["Second", "First"],
                ["Artist B", "Artist A"],
                ["", "Album Artist"],
                ["Album B", "Album A"],
                ["Rock", ""],
                ["2024-01-02 03:04:05", "2023-02-03T04:05:06Z"],
                ["Monday, January 1, 2001 at 1:02:03 PM", "missing value"],
                ["subscription", "«constant ****kPre»"],
                ["2002", "0"],
                ["1999", "2020-06-07T00:00:00Z"],
            ]
        )

        let snapshot = try LibraryMetadataSnapshot.decode(output)
        let first = try #require(snapshot.tracks.first)
        let second = try #require(snapshot.tracks.last)

        #expect(snapshot.generation.rawValue == "G1")
        #expect(snapshot.tracks.compactMap(\.databaseID?.rawValue) == ["10", "20"])
        #expect(first.name == "First")
        #expect(first.albumArtist == "Album Artist")
        #expect(first.genre == nil)
        #expect(first.year == nil)
        #expect(first.trackStatus == "«constant ****kPre»")
        #expect(first.kind == .prerelease)
        #expect(first.lastModified == nil)
        #expect(first.releaseYear == 2020)
        #expect(second.year == 2002)
        #expect(second.releaseYear == 1999)
        #expect(second.dateAdded != nil)
        #expect(second.lastModified != nil)
    }

    @Test("Malformed optional dates remain absent like the row codec")
    func preservesMalformedOptionalDateSemantics() throws {
        let output = wire(
            count: 1,
            generation: "G1",
            columns: [
                ["10"], ["Track"], ["Artist"], [""], ["Album"], [""],
                ["not a date"], ["also not a date"], [""], [""], ["not a date"],
            ]
        )

        let track = try #require(LibraryMetadataSnapshot.decode(output).tracks.first)

        #expect(track.dateAdded == nil)
        #expect(track.lastModified == nil)
        #expect(track.releaseYear == nil)
    }

    @Test("Accepts a stable empty metadata snapshot")
    func acceptsEmptySnapshot() throws {
        let output = (["METADATA", "0", "G1"] + Array(repeating: "", count: 11))
            .joined(separator: columnSeparator)

        let snapshot = try LibraryMetadataSnapshot.decode(output)

        #expect(snapshot.tracks.isEmpty)
        #expect(snapshot.generation.rawValue == "G1")
    }

    @Test("Preserves an ERROR prefix inside track metadata")
    func preservesErrorTextInMetadata() throws {
        let output = wire(
            count: 1,
            generation: "G1",
            columns: [
                ["10"], ["ERROR: Song"], ["Artist"], [""], ["Album"], [""],
                [""], [""], [""], [""], [""],
            ]
        )

        let track = try #require(LibraryMetadataSnapshot.decode(output).tracks.first)

        #expect(track.name == "ERROR: Song")
    }

    @Test("Rejects malformed columns and required identity", arguments: [
        "METADATA",
        "METADATA\u{1C}1\u{1C}G1\u{1C}10",
        "METADATA\u{1C}-1\u{1C}G1\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}",
        "METADATA\u{1C}1\u{1C}G1\u{1C}bad\u{1C}Track\u{1C}Artist\u{1C}\u{1C}Album"
            + "\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}\u{1C}",
    ])
    func rejectsMalformedMetadata(_ output: String) {
        do {
            _ = try LibraryMetadataSnapshot.decode(output)
            Issue.record("Expected malformed metadata snapshot to be rejected")
        } catch {
            // Any decoding failure is sufficient for this malformed-input boundary.
        }
    }

    @Test("Preserves empty text for observation-level absence handling")
    func preservesEmptyRequiredText() throws {
        let output = wire(
            count: 1,
            generation: "G1",
            columns: [
                ["10"], [""], [""], [""], [""], [""],
                [""], [""], [""], [""], [""],
            ]
        )

        let track = try #require(LibraryMetadataSnapshot.decode(output).tracks.first)

        #expect(track.name.isEmpty)
        #expect(track.artist.isEmpty)
    }

    @Test("Rejects duplicate database IDs")
    func rejectsDuplicateIDs() {
        let output = wire(
            count: 2,
            generation: "G1",
            columns: [
                ["10", "10"], ["First", "Second"], ["Artist", "Artist"], ["", ""],
                ["Album", "Album"], ["", ""], ["", ""], ["", ""], ["", ""],
                ["", ""], ["", ""],
            ]
        )

        do {
            _ = try LibraryMetadataSnapshot.decode(output)
            Issue.record("Expected duplicate metadata IDs to be rejected")
        } catch {
            // Any decoding failure is sufficient for this malformed-input boundary.
        }
    }

    @Test("Maps metadata producer failures to bridge errors")
    func mapsProducerFailures() {
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try LibraryMetadataSnapshot.decode("ERROR:Music is unavailable")
        }
        #expect(throws: AppleScriptBridgeError.self) {
            _ = try LibraryMetadataSnapshot.decode("RETRY:GENERATION")
        }
    }

    private func wire(count: Int, generation: String, columns: [[String]]) -> String {
        (["METADATA", String(count), generation] + columns.map { $0.joined(separator: itemSeparator) })
            .joined(separator: columnSeparator)
    }
}
