import Testing
@testable import Core
@testable import Services

@Suite("Music.app identity acquisition")
struct MusicAppIdentityTests {
    @Test("Equal rows from overlapping artist queries deduplicate by canonical ID")
    func deduplicatesEqualRows() throws {
        let track = canonicalTrack(databaseID: "AS-1")
        let requestedIDs = Set([testDatabaseID("AS-1")])

        let tracks = try AppleScriptBridge.validatedIdentityMetadata(
            [track, track],
            requestedIDs: requestedIDs
        )

        #expect(tracks == [track])
    }

    @Test("Full-library identity acquisition rejects rows outside its census")
    func rejectsUnexpectedRows() {
        let requestedID = testDatabaseID("AS-1")
        let unexpectedID = testDatabaseID("AS-2")

        #expect(throws: MusicAppIdentityError.unexpectedMetadata(unexpectedID)) {
            _ = try AppleScriptBridge.validatedIdentityMetadata(
                [canonicalTrack(databaseID: unexpectedID.rawValue)],
                requestedIDs: [requestedID]
            )
        }
    }

    @Test("Conflicting rows for one canonical ID fail closed")
    func rejectsConflictingRows() {
        let databaseID = testDatabaseID("AS-1")
        let first = canonicalTrack(databaseID: databaseID.rawValue, genre: "Rock")
        let second = canonicalTrack(databaseID: databaseID.rawValue, genre: "Metal")

        #expect(throws: MusicAppIdentityError.conflictingMetadata(databaseID)) {
            _ = try AppleScriptBridge.validatedIdentityMetadata([first, second], requestedIDs: nil)
        }
    }

    @Test("Rows without canonical Music database identity fail closed")
    func rejectsUnresolvedIdentity() {
        let sourceTrack = Track(id: "MK-1", name: "Song", artist: "Artist", album: "Album")

        #expect(throws: MusicAppIdentityError.unresolvedMetadataIdentity) {
            _ = try AppleScriptBridge.validatedIdentityMetadata([sourceTrack], requestedIDs: nil)
        }
    }

    private func canonicalTrack(databaseID: String, genre: String = "Rock") -> Track {
        Track(
            id: databaseID,
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: genre,
            appleScriptID: databaseID
        )
    }
}
