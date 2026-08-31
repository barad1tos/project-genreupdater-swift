import Core
import Testing
@testable import Services

@Suite("Processing metadata reads")
struct ProcessingMetadataReadTests {
    @Test("Sequential artist snapshots reject mixed generations")
    func rejectsMixedScopedSnapshotGenerations() throws {
        let firstGeneration = try #require(LibraryGeneration(sourceValue: "G1"))
        let secondGeneration = try #require(LibraryGeneration(sourceValue: "G2"))

        do {
            _ = try AppleScriptBridge.mergeScopedMetadataSnapshots([
                LibraryMetadataSnapshot(generation: firstGeneration, tracks: []),
                LibraryMetadataSnapshot(generation: secondGeneration, tracks: []),
            ])
            Issue.record("Expected mixed artist snapshot generations to be rejected")
        } catch AppleScriptBridgeError.libraryChanged {
            // Expected: the observer translates this transport fence into a retryable conflict.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Sequential artist snapshots preserve rows from one generation")
    func mergesStableScopedSnapshotGenerations() throws {
        let generation = try #require(LibraryGeneration(sourceValue: "G1"))
        let firstID = try #require(MusicDatabaseTrackID(rawValue: "1"))
        let secondID = try #require(MusicDatabaseTrackID(rawValue: "2"))

        let tracks = try AppleScriptBridge.mergeScopedMetadataSnapshots([
            LibraryMetadataSnapshot(generation: generation, tracks: [track(id: firstID, artist: "Target")]),
            LibraryMetadataSnapshot(generation: generation, tracks: [track(id: secondID, artist: "Guest")]),
        ])

        #expect(tracks.map(\.databaseID) == [firstID, secondID])
    }

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
