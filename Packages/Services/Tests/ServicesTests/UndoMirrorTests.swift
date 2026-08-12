import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Undo track mirror")
struct UndoMirrorTests {
    @Test("A verified undo persists the restored value before removing history")
    func revertPersistsMirror() async throws {
        let bridge = MockAppleScriptClient()
        let trackStore = try TrackDataStore.createInMemory()
        try await trackStore.saveTracks([currentTrack()])
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            trackStore: trackStore,
            directory: makeDirectory()
        )
        let entry = genreEntry()
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        let persistedTrack = try #require(try await trackStore.getTrack(byID: entry.trackID))
        #expect(persistedTrack.genre == entry.oldGenre)
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("A mirror failure keeps undo evidence after the physical write lands")
    func mirrorFailureKeepsUndo() async throws {
        let bridge = MockAppleScriptClient()
        let trackStore = MockTrackStore()
        try await trackStore.saveTracks([currentTrack()])
        await trackStore.failAppliedUpdates()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            trackStore: trackStore,
            directory: makeDirectory()
        )
        let entry = genreEntry()
        try await coordinator.recordChange(entry)

        do {
            try await coordinator.revertChange(entry)
            Issue.record("Expected track mirror finalization failure")
        } catch let error as UpdateCoordinatorError {
            guard case let .writeFinalizationFailed(trackID, effects) = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
            #expect(trackID == entry.trackID)
            #expect(effects == ["track mirror"])
        }

        #expect(await bridge.writtenProperties.count == 1)
        #expect(await coordinator.getHistory() == [entry])
    }

    private func currentTrack() -> Track {
        Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            genre: "Pop"
        )
    }

    private func genreEntry() -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T1",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine"
        )
        entry.oldGenre = "Trip-Hop"
        entry.newGenre = "Pop"
        return entry
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoMirrorTests-\(UUID().uuidString)")
    }
}
