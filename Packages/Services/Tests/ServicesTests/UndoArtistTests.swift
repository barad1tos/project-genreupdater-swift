import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Undo coupled artist changes")
struct UndoArtistTests {
    @Test("Revert restores both artist fields together")
    func revertCoupledArtistRename() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        let entry = makeEntry()
        await bridge.setUndoEntries([entry])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(tracks: trackStore),
            directory: makeDirectory()
        )
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.batchUpdates == [[
            musicUpdate(databaseID: testDatabaseID("T1"), property: .artist, value: "Massive"),
            musicUpdate(databaseID: testDatabaseID("T1"), property: .albumArtist, value: "Massive"),
        ]])
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("Revert preserves an album artist changed after the original rename")
    func revertPreservesDistinctAlbumArtist() async throws {
        let bridge = MusicAppTestAccess()
        let currentTrack = Track(
            id: "T1",
            name: "Teardrop",
            artist: "Massive Attack",
            album: "Mezzanine",
            trackStatus: TrackKind.subscription.rawValue,
            albumArtist: "Various Artists"
        )
        let observedTrack = Track(
            id: "AS1",
            name: currentTrack.name,
            artist: currentTrack.artist,
            album: currentTrack.album,
            trackStatus: currentTrack.trackStatus,
            albumArtist: currentTrack.albumArtist,
            appleScriptID: "AS1"
        )
        await bridge.setFetchedTracks([observedTrack])
        let trackStore = MockTrackStore()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MetadataUndoTrackIDMapper(
                mapping: ["T1": "AS1"],
                metadata: ["T1": currentTrack]
            ),
            stores: .init(tracks: trackStore),
            directory: makeDirectory()
        )
        let entry = makeEntry()
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.batchUpdates.isEmpty)
        #expect(await bridge.writtenProperties == [
            musicUpdate(databaseID: testDatabaseID("AS1"), property: .artist, value: "Massive"),
        ])
        #expect(await coordinator.getHistory().isEmpty)
    }

    private func makeEntry() -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: .artistRename,
            trackID: "T1",
            artist: "Massive Attack",
            trackName: "Teardrop",
            albumName: "Mezzanine"
        )
        entry.oldArtist = "Massive"
        entry.newArtist = "Massive Attack"
        entry.albumArtistChange = AlbumArtistChange(
            oldValue: "Massive",
            newValue: "Massive Attack"
        )
        return entry
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoArtistTests-\(UUID().uuidString)")
    }
}
