import Core
import Testing
@testable import Services

@Suite("Processing metadata reads")
struct ProcessingMetadataReadTests {
    @Test("Scoped snapshots fill only admitted IDs omitted by the exact artist query")
    func fillsMissingScopedMetadataByID() async throws {
        let firstID = try #require(MusicDatabaseTrackID(rawValue: "1"))
        let secondID = try #require(MusicDatabaseTrackID(rawValue: "2"))
        let firstTrack = track(id: firstID, artist: "Target")
        let secondTrack = track(id: secondID, artist: "Target ")

        let tracks = try await AppleScriptBridge.fillMissingScopedMetadata(
            requestedIDs: [firstID, secondID],
            snapshotTracks: [firstTrack, track(id: #require(MusicDatabaseTrackID(rawValue: "3")), artist: "Other")]
        ) { missingIDs in
            #expect(missingIDs == [secondID])
            return [secondTrack]
        }

        #expect(tracks.map(\.databaseID) == [firstID, secondID])
    }

    @Test("Complete scoped snapshots avoid targeted reads")
    func keepsCompleteScopedMetadataOnTheBulkPath() async throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "1"))
        let snapshotTrack = track(id: databaseID, artist: "Target")

        let tracks = try await AppleScriptBridge.fillMissingScopedMetadata(
            requestedIDs: [databaseID],
            snapshotTracks: [snapshotTrack]
        ) { _ in
            Issue.record("A complete scoped snapshot must not trigger a targeted read")
            return []
        }

        #expect(tracks == [snapshotTrack])
    }

    private func track(id: MusicDatabaseTrackID, artist: String) -> Track {
        Track(
            id: id.rawValue,
            name: "Track \(id.rawValue)",
            artist: artist,
            album: "Album",
            appleScriptID: id.rawValue
        )
    }
}
