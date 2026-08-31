import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Music.app track wire codec")
struct TrackWireCodecTests {
    @Test("Decodes canonical identity and writable metadata from a complete record")
    func decodesCompleteRecord() throws {
        let output = record(WireRecord(
            id: "AS-123",
            name: "Battery (Live)",
            artist: "Metallica",
            albumArtist: "Metallica",
            album: "Master of Puppets (Remastered)",
            genre: "Metal",
            dateAdded: "2024-02-21 13:45:00",
            lastModified: "2024-03-01 10:00:00",
            status: "local only",
            year: "1986",
            release: "1986-03-03 00:00:00"
        ))

        let track = try #require(TrackWireCodec.decodeRecords(output, scriptName: "fetch_tracks").first)

        #expect(track.databaseID?.rawValue == "AS-123")
        #expect(track.name == "Battery (Live)")
        #expect(track.album == "Master of Puppets (Remastered)")
        #expect(track.year == 1986)
        #expect(track.releaseYear == 1986)
        #expect(track.dateAdded != nil)
        #expect(track.lastModified != nil)
    }

    @Test("Rejects malformed records without exposing user metadata")
    func rejectsMalformedRecordPrivately() {
        let secret = "SECRET_TRACK_NAME"
        let output = [secret, "artist", "album"].joined(separator: String(TrackWireCodec.fieldSeparator))

        do {
            _ = try TrackWireCodec.decodeRecords(output, scriptName: "fetch_tracks")
            Issue.record("Expected a wire decode error")
        } catch let error as TrackWireError {
            #expect(!error.detail.contains(secret))
            #expect(error.detail.contains("got 3"))
        } catch {
            Issue.record("Expected TrackWireError, got \(error)")
        }
    }

    @Test("Treats zero year fields as missing")
    func treatsZeroYearsAsMissing() throws {
        let track = try #require(TrackWireCodec.decodeRecords(
            record(WireRecord(id: "AS-0", year: "0", release: "0")),
            scriptName: "fetch_tracks"
        ).first)

        #expect(track.year == nil)
        #expect(track.releaseYear == nil)
    }

    @Test("Canonicalizes unknown AppleScript status constants")
    func canonicalizesUnknownStatusConstants() throws {
        let track = try #require(TrackWireCodec.decodeRecords(
            record(WireRecord(id: "AS-UNKNOWN", status: "«constant ****kNew»")),
            scriptName: "fetch_tracks"
        ).first)

        #expect(track.trackStatus == "unknown")
    }

    @Test("Preserves unknown text statuses")
    func preservesUnknownTextStatuses() throws {
        let track = try #require(TrackWireCodec.decodeRecords(
            record(WireRecord(id: "AS-FUTURE", status: "archived")),
            scriptName: "fetch_tracks"
        ).first)

        #expect(track.trackStatus == "archived")
    }

    private struct WireRecord {
        let id: String
        var name = "Song"
        var artist = "Artist"
        var albumArtist = "Artist"
        var album = "Album"
        var genre = "Rock"
        var dateAdded = ""
        var lastModified = ""
        var status = "matched"
        var year = "1999"
        var release = "2001"
    }

    private func record(_ wire: WireRecord) -> String {
        [
            wire.id, wire.name, wire.artist, wire.albumArtist, wire.album, wire.genre,
            wire.dateAdded, wire.lastModified, wire.status, wire.year, wire.release, "",
        ].joined(separator: String(TrackWireCodec.fieldSeparator))
    }
}
