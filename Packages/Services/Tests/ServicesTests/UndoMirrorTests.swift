import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Undo track mirror")
struct UndoMirrorTests {
    @Test("A verified undo persists the restored value before removing history")
    func revertPersistsMirror() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = try TrackDataStore.createInMemory()
        try await trackStore.seedMirror([currentTrack()])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            stores: .init(tracks: trackStore),
            directory: makeDirectory()
        )
        let entry = genreEntry()
        await bridge.setFetchedTracks([currentTrack()])
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        let persistedTrack = try #require(try await trackStore.getTrack(byID: entry.trackID))
        #expect(persistedTrack.genre == entry.oldGenre)
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("A mirror failure keeps undo evidence after the physical write lands")
    func mirrorFailureKeepsUndo() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([currentTrack()])
        await trackStore.failAppliedUpdates()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            stores: .init(tracks: trackStore),
            directory: makeDirectory()
        )
        let entry = genreEntry()
        await bridge.setFetchedTracks([currentTrack()])
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
        let bridge = MusicAppTestAccess()
        await bridge.setFetchedTracks([currentTrack(genre: "Electronic")])
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([currentTrack(genre: "Electronic")])
        await trackStore.failAppliedUpdates()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            stores: .init(tracks: trackStore),
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
        let bridge = MusicAppTestAccess()
        let cache = MockCacheService()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(cache: cache),
            directory: makeDirectory()
        )
        let entry = artistEntry()
        await bridge.setUndoEntries([entry])
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

    @Test("Artist undo after upgrade preserves the restored original across relaunch")
    func artistUndoRelaunch() async throws {
        let storeURL = try makeStoreURL()
        defer { removeStore(at: storeURL) }
        var entry = artistEntry()
        entry.albumArtistChange = AlbumArtistChange(
            oldValue: "Florence and the Machine",
            newValue: "Florence + the Machine"
        )

        do {
            let container = try makeContainer(at: storeURL)
            let trackStore = TrackDataStore(modelContainer: container)
            let changeLogStore = ChangeLogDataStore(modelContainer: container)
            try await trackStore.seedMirror([Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.newArtist ?? "",
                album: entry.albumName,
                albumArtist: entry.albumArtistChange?.newValue,
                appleScriptID: entry.trackID
            )])
            let bridge = MusicAppTestAccess()
            await bridge.setFetchedTracks([Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.newArtist ?? "",
                album: entry.albumName,
                albumArtist: entry.albumArtistChange?.newValue,
                appleScriptID: entry.trackID
            )])
            let coordinator = UndoCoordinator(
                musicApp: bridge,
                stores: .init(changeLog: changeLogStore, tracks: trackStore),
                directory: makeDirectory()
            )

            try await coordinator.recordChange(entry)
            try await coordinator.revertChange(entry)
        }

        let relaunchedContainer = try makeContainer(at: storeURL)
        let relaunchedStore = TrackDataStore(modelContainer: relaunchedContainer)
        let relaunchedLog = ChangeLogDataStore(modelContainer: relaunchedContainer)
        let persistedTrack = try #require(try await relaunchedStore.getTrack(byID: entry.trackID))
        #expect(persistedTrack.artist == entry.oldArtist)
        #expect(persistedTrack.albumArtist == entry.albumArtistChange?.oldValue)
        #expect(persistedTrack.originalArtist == entry.oldArtist)
        #expect(try await relaunchedLog.loadAll().isEmpty)
    }

    @Test("Album undo after upgrade preserves the restored original across relaunch")
    func albumUndoRelaunch() async throws {
        let storeURL = try makeStoreURL()
        defer { removeStore(at: storeURL) }
        let entry = albumEntry()

        do {
            let trackStore = try makeStore(at: storeURL)
            try await trackStore.seedMirror([Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.artist,
                album: entry.newAlbumName ?? "",
                appleScriptID: entry.trackID
            )])
            let bridge = MusicAppTestAccess()
            await bridge.setUndoEntries([entry])
            let coordinator = UndoCoordinator(
                musicApp: bridge,
                stores: .init(tracks: trackStore),
                directory: makeDirectory()
            )

            try await coordinator.revertChange(entry)
        }

        let relaunchedStore = try makeStore(at: storeURL)
        let persistedTrack = try #require(try await relaunchedStore.getTrack(byID: entry.trackID))
        #expect(persistedTrack.album == entry.oldAlbumName)
        #expect(persistedTrack.originalAlbum == entry.oldAlbumName)
    }

    @Test("Year undo after upgrade preserves the restored year across relaunch")
    func yearUndoRelaunch() async throws {
        let storeURL = try makeStoreURL()
        defer { removeStore(at: storeURL) }
        let entry = yearEntry()

        do {
            let trackStore = try makeStore(at: storeURL)
            try await trackStore.seedMirror([Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.artist,
                album: entry.albumName,
                year: entry.newYear,
                appleScriptID: entry.trackID
            )])
            let bridge = MusicAppTestAccess()
            await bridge.setUndoEntries([entry])
            let coordinator = UndoCoordinator(
                musicApp: bridge,
                stores: .init(tracks: trackStore),
                directory: makeDirectory()
            )

            try await coordinator.revertChange(entry)
        }

        let relaunchedStore = try makeStore(at: storeURL)
        let persistedTrack = try #require(try await relaunchedStore.getTrack(byID: entry.trackID))
        #expect(persistedTrack.year == entry.oldYear)
        #expect(persistedTrack.yearBeforeMGU == entry.oldYear)
        #expect(persistedTrack.yearSetByMGU == entry.oldYear)
    }

    @Test("Empty-year undo survives relaunch with one physical clear and no history")
    func emptyUndoRelaunch() async throws {
        let storeURL = try makeStoreURL()
        defer { removeStore(at: storeURL) }
        let bridge = MusicAppTestAccess()
        let checkpointDirectory = makeDirectory()
        var entry = yearEntry()
        entry.oldYear = nil

        do {
            let container = try makeContainer(at: storeURL)
            let trackStore = TrackDataStore(modelContainer: container)
            let changeLogStore = ChangeLogDataStore(modelContainer: container)
            let current = Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.artist,
                album: entry.albumName,
                year: entry.newYear,
                appleScriptID: entry.trackID
            )
            try await trackStore.seedMirror([current])
            await bridge.setFetchedTracks([current])
            let coordinator = UndoCoordinator(
                musicApp: bridge,
                stores: .init(changeLog: changeLogStore, tracks: trackStore),
                directory: checkpointDirectory
            )

            try await coordinator.recordChange(entry)
            try await coordinator.revertChange(entry)
        }

        let relaunchedContainer = try makeContainer(at: storeURL)
        let relaunchedStore = TrackDataStore(modelContainer: relaunchedContainer)
        let relaunchedLog = ChangeLogDataStore(modelContainer: relaunchedContainer)
        let persistedTrack = try #require(try await relaunchedStore.getTrack(byID: entry.trackID))
        #expect(persistedTrack.year == nil)
        #expect(persistedTrack.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(persistedTrack.yearSetByMGU == MusicAppYear.missingValue)
        #expect(try await relaunchedLog.loadAll().isEmpty)
        #expect(await bridge.writtenProperties == [
            musicUpdate(databaseID: testDatabaseID(entry.trackID), property: .year, value: "0"),
        ])
        #expect(!FileManager.default.fileExists(
            atPath: checkpointDirectory.appendingPathComponent("pending-year-revert.json").path
        ))
    }

    private func currentTrack(genre: String = "Pop") -> Track {
        Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            genre: genre,
            appleScriptID: "T1"
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

    private func albumEntry() -> ChangeLogEntry {
        ChangeLogEntry(
            id: UUID(),
            timestamp: .now,
            changeType: .albumCleaning,
            trackID: "T3",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine (Remastered)",
            oldAlbumName: "Mezzanine (Remastered)",
            newAlbumName: "Mezzanine"
        )
    }

    private func yearEntry() -> ChangeLogEntry {
        ChangeLogEntry(
            id: UUID(),
            timestamp: .now,
            changeType: .yearUpdate,
            trackID: "T4",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine",
            oldYear: 1998,
            newYear: 2019
        )
    }

    private func makeStore(at storeURL: URL) throws -> TrackDataStore {
        try TrackDataStore(modelContainer: makeContainer(at: storeURL))
    }

    private func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema([PersistedTrack.self, PersistedMirrorState.self, PersistedChangeLogEntry.self])
        let configuration = ModelConfiguration(
            "UndoMirrorTests",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeStoreURL() throws -> URL {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("GenreUpdater.store")
    }

    private func removeStore(at storeURL: URL) {
        do {
            try FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        } catch {
            Issue.record("Failed to remove undo mirror fixture: \(error)")
        }
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoMirrorTests-\(UUID().uuidString)")
    }
}
