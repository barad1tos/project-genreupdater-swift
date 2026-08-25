import Core
import Testing
@testable import Services

@Suite("Music.app targeted verification")
struct MusicAppVerificationTests {
    @Test("Missing requested rows remain a valid deleted-track result")
    func permitsMissingRows() throws {
        let firstID = try databaseID("A")
        let missingID = try databaseID("B")
        let firstTrack = verifiedTrack(readID: "observed-A", databaseID: firstID)

        let tracks = try AppleScriptBridge.validatedMetadata(
            [firstTrack],
            requestedIDs: [firstID, missingID]
        )

        #expect(tracks == [firstTrack])
    }

    @Test("A row without canonical identity fails verification")
    func rejectsUnresolvedRows() throws {
        let requestedID = try databaseID("A")
        let unresolved = Track(id: "observed-A", name: "Track", artist: "Artist", album: "Album")

        #expect(throws: MusicAppVerificationError.unresolvedMetadataIdentity) {
            try AppleScriptBridge.validatedMetadata([unresolved], requestedIDs: [requestedID])
        }
    }

    @Test("An unrequested canonical row fails verification")
    func rejectsUnexpectedRows() throws {
        let requestedID = try databaseID("A")
        let unexpectedID = try databaseID("B")

        #expect(throws: MusicAppVerificationError.unexpectedMetadata(unexpectedID)) {
            try AppleScriptBridge.validatedMetadata(
                [verifiedTrack(readID: "observed-B", databaseID: unexpectedID)],
                requestedIDs: [requestedID]
            )
        }
    }

    @Test("Duplicate canonical rows fail verification")
    func rejectsDuplicateRows() throws {
        let requestedID = try databaseID("A")

        #expect(throws: MusicAppVerificationError.duplicateMetadata(requestedID)) {
            try AppleScriptBridge.validatedMetadata(
                [
                    verifiedTrack(readID: "first-A", databaseID: requestedID),
                    verifiedTrack(readID: "second-A", databaseID: requestedID),
                ],
                requestedIDs: [requestedID]
            )
        }
    }

    private func databaseID(_ value: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: value))
    }

    private func verifiedTrack(readID: String, databaseID: MusicDatabaseTrackID) -> Track {
        Track(
            id: readID,
            name: "Track",
            artist: "Artist",
            album: "Album",
            appleScriptID: databaseID.rawValue
        )
    }
}
