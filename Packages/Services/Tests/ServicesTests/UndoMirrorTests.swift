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

    @Test("Batch undo stops after a verified write cannot update the mirror")
    func batchStopsAtMirrorFailure() async throws {
        let bridge = MockAppleScriptClient()
        await bridge.setFetchedTracks([currentTrack(genre: "Electronic")])
        let trackStore = MockTrackStore()
        try await trackStore.saveTracks([currentTrack(genre: "Electronic")])
        await trackStore.failAppliedUpdates()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            trackStore: trackStore,
            directory: makeDirectory()
        )
        let newer = genreEntry(
            oldGenre: "Pop",
            newGenre: "Electronic",
            timestamp: .now
        )
        let older = genreEntry(
            oldGenre: "Trip-Hop",
            newGenre: "Pop",
            timestamp: newer.timestamp.addingTimeInterval(-1)
        )
        try await coordinator.recordChanges([older, newer])

        do {
            try await coordinator.revertBatch([older, newer])
            Issue.record("Expected track mirror finalization failure")
        } catch let error as UpdateCoordinatorError {
            guard case .writeFinalizationFailed = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
        }

        let writes = await bridge.writtenProperties
        #expect(writes.count == 1)
        #expect(writes.first?.value == "Pop")
        #expect(await coordinator.getHistory().count == 2)
    }

    @Test("Artist undo invalidates caches for current and restored identities")
    func artistUndoInvalidatesBothIdentities() async throws {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            cache: cache,
            directory: makeDirectory()
        )
        let entry = artistEntry()
        await cache.storeAlbumYear(
            artist: entry.oldArtist ?? "",
            album: entry.albumName,
            year: 2009,
            confidence: 100
        )
        await cache.storeAlbumYear(
            artist: entry.newArtist ?? "",
            album: entry.albumName,
            year: 2009,
            confidence: 100
        )

        try await coordinator.revertChange(entry)

        #expect(await cache.getAlbumYear(artist: entry.oldArtist ?? "", album: entry.albumName) == nil)
        #expect(await cache.getAlbumYear(artist: entry.newArtist ?? "", album: entry.albumName) == nil)
    }

    private func currentTrack(genre: String = "Pop") -> Track {
        Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            genre: genre
        )
    }

    private func genreEntry(
        oldGenre: String = "Trip-Hop",
        newGenre: String = "Pop",
        timestamp: Date = .now
    ) -> ChangeLogEntry {
        ChangeLogEntry(
            id: UUID(),
            timestamp: timestamp,
            changeType: .genreUpdate,
            trackID: "T1",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine",
            oldGenre: oldGenre,
            newGenre: newGenre
        )
    }

    private func artistEntry() -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: .artistRename,
            trackID: "T2",
            artist: "Florence and the Machine",
            trackName: "Dog Days Are Over",
            albumName: "Lungs"
        )
        entry.oldArtist = "Florence and the Machine"
        entry.newArtist = "Florence + the Machine"
        return entry
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoMirrorTests-\(UUID().uuidString)")
    }
}
