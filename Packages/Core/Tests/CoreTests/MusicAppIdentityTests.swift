import Foundation
import Testing
@testable import Core

@Suite("Music.app identity values")
struct MusicAppIdentityTests {
    @Test("Database identity keeps string wire compatibility")
    func preservesStringWireValue() throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "4107"))

        let encoded = try JSONEncoder().encode(databaseID)
        let decoded = try JSONDecoder().decode(MusicDatabaseTrackID.self, from: encoded)

        #expect(String(data: encoded, encoding: .utf8) == "\"4107\"")
        #expect(decoded == databaseID)
    }

    @Test("Database identity rejects empty source and wire values")
    func rejectsEmptyValues() throws {
        #expect(MusicDatabaseTrackID(rawValue: "  ") == nil)

        let encodedEmpty = Data("\"\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MusicDatabaseTrackID.self, from: encodedEmpty)
        }
    }

    @Test("MusicKit-origin track has no database identity until AppleScript resolves it")
    func rejectsUnresolvedIdentity() {
        let track = Track(id: "music-kit-query-id", name: "Same Song", artist: "Primary Artist", album: "Same Album")

        #expect(track.databaseID == nil)
    }

    @Test("Track keeps its resolved database identity through existing Codable")
    func preservesResolvedIdentity() throws {
        let track = Track(
            id: "music-kit-query-id",
            name: "Same Song",
            artist: "Primary Artist",
            album: "Same Album",
            appleScriptID: "4107"
        )

        let encoded = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: encoded)

        #expect(decoded.id == "music-kit-query-id")
        #expect(decoded.databaseID == MusicDatabaseTrackID(rawValue: "4107"))
        #expect(decoded.appleScriptID == "4107")
    }
}
