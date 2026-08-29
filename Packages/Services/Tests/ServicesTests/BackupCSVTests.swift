import Foundation
import Testing
@testable import Core
@testable import Services

private func makeBackupTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupCSVTests-\(UUID().uuidString)")
}

private struct TestBackupCheckpoint: Encodable {
    let entry: ChangeLogEntry
    let phase: String
}

private func expectTrackYearState(
    _ track: Track,
    year: Int,
    originalYear: Int
) {
    #expect(track.year == year)
    #expect(track.yearBeforeMGU == originalYear)
    #expect(track.yearSetByMGU == year)
}

@Suite("UndoCoordinator — backup CSV year revert")
struct BackupCSVTests {
    @Test("Parse backup CSV filters artist and album")
    func parseBackupCSVFiltersArtistAndAlbum() throws {
        let csv = """
        id,name,artist,album,year,year_before_mgu,year_set_by_mgu
        T1,"Song, One",Massive Attack,Mezzanine,1998,1997,1999
        T2,Other,Massive Attack,Protection,,1994,1995
        T3,Skip,Other Artist,Mezzanine,2000,,
        """

        let targets = try YearBackupCSVParser.parse(
            csv,
            artist: "massive attack",
            album: "mezzanine"
        )

        #expect(
            targets == [
                YearBackupRevertTarget(
                    trackID: "T1",
                    trackName: "Song, One",
                    albumName: "Mezzanine",
                    year: 1998
                ),
            ]
        )
    }

    @Test("Revert backup CSV writes years and records revert history")
    func revertBackupCSVWritesYearsAndRecordsHistory() async throws {
        let bridge = MusicAppTestAccess()
        let container = try ModelContainerFactory.createInMemory()
        let trackStore = TrackDataStore(modelContainer: container)
        let historyStore = ChangeLogDataStore(modelContainer: container)
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        ,Teardrop,Massive Attack,Mezzanine,1998
        MISSING,Missing Track,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
            Track(
                id: "T2",
                name: "Teardrop",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2020
            ),
        ]
        try await trackStore.seedMirror(tracks)
        await bridge.setMutationTracks(tracks)

        let result = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: tracks
        )

        #expect(result.parsedCount == 3)
        #expect(result.updatedCount == 2)
        #expect(result.missingCount == 1)

        let written = await bridge.writtenProperties
        #expect(written.count == 2)
        #expect(written.map(\.databaseID.rawValue) == ["T1", "T2"])
        #expect(written.map(\.property) == [.year, .year])
        #expect(written.map(\.value) == ["1998", "1998"])

        let history = await coordinator.getHistory()
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.changeType == .yearRevert })
        #expect(history.contains { $0.trackID == "T1" && $0.oldYear == 2019 && $0.newYear == 1998 })
        #expect(history.contains { $0.trackID == "T2" && $0.oldYear == 2020 && $0.newYear == 1998 })
        let firstTrack = try #require(try await trackStore.getTrack(byID: "T1"))
        let secondTrack = try #require(try await trackStore.getTrack(byID: "T2"))
        expectTrackYearState(firstTrack, year: 1998, originalYear: 2019)
        expectTrackYearState(secondTrack, year: 1998, originalYear: 2020)
    }

    @Test("Mapped backup writes finalize and remove the checkpoint by canonical database ID")
    func mappedBackupUsesDatabaseID() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        let directory = makeBackupTempDirectory()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            stores: .init(tracks: trackStore),
            directory: directory
        )
        let sourceTrack = Track(
            id: "MK1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019,
            appleScriptID: "AS1"
        )
        let storedTrack = Track(
            id: "AS1",
            name: sourceTrack.name,
            artist: sourceTrack.artist,
            album: sourceTrack.album,
            year: sourceTrack.year,
            appleScriptID: "AS1"
        )
        try await trackStore.seedMirror([storedTrack])
        await bridge.setMutationTracks([storedTrack])

        let result = try await coordinator.revertYearsFromBackupCSV(
            """
            id,name,artist,album,year_before_mgu
            MK1,Angel,Massive Attack,Mezzanine,1998
            """,
            artist: sourceTrack.artist,
            album: sourceTrack.album,
            currentTracks: [sourceTrack]
        )

        #expect(result.updatedCount == 1)
        #expect(await bridge.writtenProperties.map(\.databaseID.rawValue) == ["AS1"])
        #expect(await coordinator.getHistory().map(\.trackID) == ["AS1"])
        #expect(try await trackStore.getTrack(byID: "AS1")?.year == 1998)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pending-year-revert.json").path
        ))
    }

    @Test("Atomic finalization failure retries without another physical write")
    func mirrorFailureRetryFinalizesOnce() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        let directory = makeBackupTempDirectory()
        let tracks = [
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ]
        try await trackStore.seedMirror(tracks)
        await trackStore.failAppliedUpdates()
        await bridge.setFetchedTracks(tracks)
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(tracks: trackStore),
            directory: directory
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """

        await expectFinalizationFailure {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                album: "Mezzanine",
                currentTracks: tracks
            )
        }

        #expect(await coordinator.getHistory().isEmpty)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 2019)

        await trackStore.resumeAppliedUpdates()
        let retryCoordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(tracks: trackStore),
            directory: directory
        )
        var liveTrack = tracks[0]
        liveTrack.year = 1998
        let retryResult = try await retryCoordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: [liveTrack]
        )

        #expect(retryResult.updatedCount == 1)
        #expect(retryResult.skippedCount == 0)
        #expect(await bridge.writtenProperties.count == 1)
        #expect(await retryCoordinator.getHistory().count == 1)
        try await expectRestoredYear(in: trackStore)
    }

    @Test("Retry preserves distinct evidence for identical restores")
    func distinctRestoreEvidence() async throws {
        let bridge = MusicAppTestAccess()
        let container = try ModelContainerFactory.createInMemory()
        let trackStore = TrackDataStore(modelContainer: container)
        let historyStore = ChangeLogDataStore(modelContainer: container)
        let directory = makeBackupTempDirectory()
        let track = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
        try await trackStore.seedMirror([track])
        await bridge.setMutationTracks([track])
        _ = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            currentTracks: [track]
        )

        try await trackStore.seedMirror([track])
        await bridge.setMutationTracks([track])
        _ = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            currentTracks: [track]
        )

        let entries = try await historyStore.loadAll()
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test("Checkpoint failure blocks a physical write before dispatch")
    func checkpointFailureBlocksWrite() async throws {
        let bridge = MusicAppTestAccess()
        let historyStore = MockChangeLogStore()
        let trackStore = MockTrackStore()
        let directory = makeBackupTempDirectory()
        try Data().write(to: directory)
        let track = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
        try await trackStore.seedMirror([track])
        await bridge.setMutationTracks([track])

        await expectFinalizationFailure(effects: ["backup recovery checkpoint"]) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                currentTracks: [track]
            )
        }

        #expect(await bridge.writtenProperties.isEmpty)
        #expect(await historyStore.entries.isEmpty)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 2019)

        try FileManager.default.removeItem(at: directory)
        let retryCoordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
        let result = try await retryCoordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            currentTracks: [track]
        )

        #expect(result.updatedCount == 1)
        #expect(await bridge.writtenProperties.count == 1)
        let history = await retryCoordinator.getHistory()
        #expect(history.count == 1)
        #expect(history.first?.oldYear == 2019)
        #expect(history.first?.newYear == 1998)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 1998)
    }

    @Test("A stale recovery checkpoint blocks backup writes")
    func staleCheckpointBlocksWrite() async throws {
        let bridge = MusicAppTestAccess()
        let directory = makeBackupTempDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var staleEntry = ChangeLogEntry(
            changeType: .yearRevert,
            trackID: "T1",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine"
        )
        staleEntry.oldYear = 2019
        staleEntry.newYear = 2001
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TestBackupCheckpoint(entry: staleEntry, phase: "prepared")).write(
            to: directory.appendingPathComponent("pending-year-revert.json")
        )
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            directory: directory
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """
        let track = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019
        )
        await bridge.setMutationTracks([track])

        await expectFinalizationFailure(effects: ["prior backup recovery checkpoint"]) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                currentTracks: [track]
            )
        }

        #expect(await bridge.writtenProperties.isEmpty)
    }

    @Test("Corrupt recovery checkpoint blocks backup writes")
    func corruptCheckpointBlocksWrites() async throws {
        let bridge = MusicAppTestAccess()
        let directory = makeBackupTempDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("pending-year-revert.json")
        )
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            directory: directory
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """
        let track = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019
        )
        await bridge.setMutationTracks([track])

        do {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                album: "Mezzanine",
                currentTracks: [track]
            )
            Issue.record("Expected backup recovery checkpoint failure")
        } catch let error as UpdateCoordinatorError {
            guard case .writeFinalizationFailed = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
        }

        #expect(await bridge.writtenProperties.isEmpty)
    }

    @Test("Backup CSV revert invalidates album API and snapshot caches")
    func backupCSVRevertInvalidatesAlbumAPIAndSnapshotCaches() async throws {
        let bridge = MusicAppTestAccess()
        let cache = MockCacheService()
        let snapshotService = MockUndoLibrarySnapshotService()
        let trackStore = MockTrackStore()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(tracks: trackStore, cache: cache),
            librarySnapshotService: snapshotService,
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ]
        try await trackStore.seedMirror(tracks)
        await bridge.setMutationTracks(tracks)

        await cache.storeAlbumYear(artist: "Massive Attack", album: "Mezzanine", year: 2019, confidence: 100)
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019,
            source: "discogs",
            timestamp: .now,
            ttl: nil
        ))

        _ = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: tracks
        )

        #expect(await cache.getAlbumYear(artist: "Massive Attack", album: "Mezzanine") == nil)
        #expect(
            await cache.getCachedAPIResult(
                artist: "Massive Attack",
                album: "Mezzanine",
                source: "discogs"
            ) == nil
        )
        #expect(await snapshotService.wasCleared())
    }

    @Test("Backup CSV no-change rows are reported as skipped without history")
    func backupCSVNoChangeRowsAreReportedAsSkippedWithoutHistory() async throws {
        let bridge = MusicAppTestAccess()
        await bridge.setSingleWriteResult(.noChange)
        let trackStore = try TrackDataStore.createInMemory()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(tracks: trackStore),
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 1998
            ),
        ]
        try await trackStore.seedMirror([
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ])
        await bridge.setMutationTracks(tracks)

        let result = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: tracks
        )

        #expect(result.updatedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.failedCount == 0)
        #expect(await coordinator.getHistory().isEmpty)
        let mirroredTrack = try #require(try await trackStore.getTrack(byID: "T1"))
        #expect(mirroredTrack.year == 1998)
        #expect(mirroredTrack.yearBeforeMGU == nil)
        #expect(mirroredTrack.yearSetByMGU == nil)
    }

    @Test("Backup CSV revert refuses missing AppleScript ID mapping")
    func backupCSVRevertRefusesMissingAppleScriptIDMapping() async throws {
        let bridge = MusicAppTestAccess()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        MK1,Angel,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "MK1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ]

        let result = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: tracks
        )

        #expect(result.updatedCount == 0)
        #expect(result.failedCount == 1)
        #expect(result.firstFailureDescription?.contains("AppleScript ID mapping") == true)
        #expect(result.firstFailureDescription?.contains("MK1") == false)

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)

        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }

    @Test("Backup CSV write failure leaves terminal recovery evidence")
    func writeFailureKeepsCheckpoint() async throws {
        let bridge = MusicAppTestAccess()
        await bridge.setCustomWriteError(RawTrackIDWriteError(trackID: "MK1"))
        let trackStore = MockTrackStore()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: CanonicalUndoMapper(),
            stores: .init(tracks: trackStore),
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        MK1,Angel,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "MK1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ]
        try await trackStore.seedMirror(tracks)
        await bridge.setMutationTracks(tracks)

        do {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                album: "Mezzanine",
                currentTracks: tracks
            )
            Issue.record("Expected pending recovery failure")
        } catch let error as UpdateCoordinatorError {
            guard case let .writeFinalizationFailed(trackID, effects) = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
            #expect(trackID == "MK1")
            #expect(effects == ["backup recovery checkpoint"])
        }

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)

        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }

    private func expectFinalizationFailure(
        effects expectedEffects: [String]? = nil,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected post-write finalization failure")
        } catch let error as UpdateCoordinatorError {
            guard case let .writeFinalizationFailed(trackID, effects) = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
            #expect(trackID == "T1")
            if let expectedEffects {
                #expect(effects == expectedEffects)
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectRestoredYear(in store: MockTrackStore) async throws {
        let track = try #require(try await store.getTrack(byID: "T1"))
        #expect(track.year == 1998)
        #expect(track.yearBeforeMGU == 1998)
        #expect(track.yearSetByMGU == 1998)
    }
}
