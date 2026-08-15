import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Undo coupled artist changes")
struct UndoArtistTests {
    @Test("Revert restores both artist fields together")
    func revertCoupledArtistRename() async throws {
        let bridge = MockAppleScriptClient()
        await bridge.setFetchedTracks([
            Track(
                id: "T1",
                name: "Teardrop",
                artist: "Massive Attack",
                album: "Mezzanine",
                albumArtist: "Massive Attack"
            ),
        ])
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeDirectory())
        let entry = makeEntry()
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.batchUpdates == [[
            TrackPropertyUpdate(trackID: "T1", property: "artist", value: "Massive"),
            TrackPropertyUpdate(trackID: "T1", property: "album_artist", value: "Massive"),
        ]])
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("Revert preserves an album artist changed after the original rename")
    func revertPreservesDistinctAlbumArtist() async throws {
        let bridge = MockAppleScriptClient()
        let currentTrack = Track(
            id: "T1",
            name: "Teardrop",
            artist: "Massive Attack",
            album: "Mezzanine",
            trackStatus: TrackKind.subscription.rawValue,
            albumArtist: "Various Artists"
        )
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: MetadataUndoTrackIDMapper(
                mapping: ["T1": "AS1"],
                metadata: ["T1": currentTrack]
            ),
            directory: makeDirectory()
        )
        let entry = makeEntry()
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.batchUpdates.isEmpty)
        #expect(await bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "AS1", property: "artist", value: "Massive"),
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
