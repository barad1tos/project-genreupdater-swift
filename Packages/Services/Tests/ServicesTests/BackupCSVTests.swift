import Foundation
import Testing
@testable import Core
@testable import Services

private func makeBackupTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupCSVTests-\(UUID().uuidString)")
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
        let bridge = MockAppleScriptClient()
        let trackStore = try TrackDataStore.createInMemory()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            trackStore: trackStore,
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
        try await trackStore.saveTracks(tracks)

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
        #expect(written[0].trackID == "T1")
        #expect(written[0].property == "year")
        #expect(written[0].value == "1998")
        #expect(written[1].trackID == "T2")
        #expect(written[1].property == "year")
        #expect(written[1].value == "1998")

        let history = await coordinator.getHistory()
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.changeType == .yearRevert })
        #expect(history.contains { $0.trackID == "T1" && $0.oldYear == 2019 && $0.newYear == 1998 })
        #expect(history.contains { $0.trackID == "T2" && $0.oldYear == 2020 && $0.newYear == 1998 })
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 1998)
        #expect(try await trackStore.getTrack(byID: "T2")?.year == 1998)
    }

    @Test("History failure preserves mirror evidence and retry finalizes once")
    func historyFailureRetryFinalizesOnce() async throws {
        let bridge = MockAppleScriptClient()
        let store = MockChangeLogStore()
        await store.failSaves()
        let trackStore = MockTrackStore()
        let directory = makeBackupTempDirectory()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: store,
            trackStore: trackStore,
            directory: directory
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
        try await trackStore.saveTracks(tracks)
        await bridge.setFetchedTracks(tracks)

        await expectFinalizationFailure(effects: ["change history"]) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                album: "Mezzanine",
                currentTracks: tracks
            )
        }

        let written = await bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written.first?.value == "1998")
        #expect(await coordinator.getHistory().isEmpty)
        #expect(await store.entries.isEmpty)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 2019)

        await store.resumeSaves()
        let retryCoordinator = UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: store,
            trackStore: trackStore,
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

        #expect(retryResult.skippedCount == 1)
        #expect(await store.entries.count == 1)
        #expect(await store.entries.first?.oldYear == 2019)
        #expect(await store.entries.first?.newYear == 1998)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 1998)
    }

    @Test("Mirror failure retry preserves one durable backup history entry")
    func mirrorFailureRetryFinalizesOnce() async throws {
        let bridge = MockAppleScriptClient()
        let historyStore = MockChangeLogStore()
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
        try await trackStore.saveTracks(tracks)
        await trackStore.failAppliedUpdates()
        await bridge.setFetchedTracks(tracks)
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: historyStore,
            trackStore: trackStore,
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

        #expect(await historyStore.entries.count == 1)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 2019)

        await trackStore.resumeAppliedUpdates()
        let retryCoordinator = UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: historyStore,
            trackStore: trackStore,
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

        #expect(retryResult.skippedCount == 1)
        #expect(await historyStore.entries.count == 1)
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 1998)
    }

    @Test("Retry preserves distinct evidence for identical restores")
    func distinctRestoreEvidence() async throws {
        let bridge = MockAppleScriptClient()
        let historyStore = MockChangeLogStore()
        let trackStore = MockTrackStore()
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
            scriptBridge: bridge,
            changeLogStore: historyStore,
            trackStore: trackStore,
            directory: directory
        )
        try await trackStore.saveTracks([track])
        await bridge.setFetchedTracks([track])
        _ = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            currentTracks: [track]
        )

        try await trackStore.saveTracks([track])
        await bridge.setFetchedTracks([track])
        await historyStore.failSaves()
        await expectFinalizationFailure(effects: ["change history"]) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                currentTracks: [track]
            )
        }

        await historyStore.resumeSaves()
        var restoredTrack = track
        restoredTrack.year = 1998
        let retryCoordinator = UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: historyStore,
            trackStore: trackStore,
            directory: directory
        )
        _ = try await retryCoordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            currentTracks: [restoredTrack]
        )

        let entries = await historyStore.entries
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test("Corrupt recovery checkpoint blocks backup writes")
    func corruptCheckpointBlocksWrites() async throws {
        let bridge = MockAppleScriptClient()
        let directory = makeBackupTempDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("pending-year-revert.json")
        )
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
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
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let snapshotService = MockUndoLibrarySnapshotService()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            cache: cache,
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
        let bridge = MockAppleScriptClient()
        await bridge.setSingleWriteResult(.noChange)
        let trackStore = try TrackDataStore.createInMemory()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            trackStore: trackStore,
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
        try await trackStore.saveTracks([
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ])

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
        #expect(try await trackStore.getTrack(byID: "T1")?.year == 1998)
    }

    @Test("Backup CSV revert refuses missing AppleScript ID mapping")
    func backupCSVRevertRefusesMissingAppleScriptIDMapping() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
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

    @Test("Backup CSV write failure description is public-safe")
    func backupCSVWriteFailureDescriptionIsPublicSafe() async throws {
        let bridge = MockAppleScriptClient()
        await bridge.setCustomWriteError(RawTrackIDWriteError(trackID: "MK1"))
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
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
        #expect(result.firstFailureDescription == "AppleScript write failed")

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
}
