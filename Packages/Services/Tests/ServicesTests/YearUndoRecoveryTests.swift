import Foundation
import Testing
@testable import Core
@testable import Services

private struct YearUndoFixture {
    let bridge = MusicAppTestAccess()
    let historyStore = MockChangeLogStore()
    let trackStore = MockTrackStore()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("YearUndoRecoveryTests-\(UUID().uuidString)")
    let idMapper: (any TrackIDMapping)?
    let entry: ChangeLogEntry

    init(idMapper: (any TrackIDMapping)? = nil, trackID: String = "T1") {
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: trackID,
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine"
        )
        entry.oldYear = nil
        entry.newYear = 2019
        self.idMapper = idMapper
        self.entry = entry
    }

    var checkpointURL: URL {
        directory.appendingPathComponent("pending-year-revert.json")
    }

    func coordinator() -> UndoCoordinator {
        UndoCoordinator(
            musicApp: bridge,
            idMapper: idMapper,
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
    }

    func prepare() async throws {
        let track = makeTrack(year: 2019)
        try await trackStore.seedMirror([track])
        await bridge.setFetchedTracks([track])
        try await coordinator().recordChange(entry)
    }

    func prepareChain(originYear: Int?) async throws -> ChangeLogEntry {
        var oldestEntry = entry
        oldestEntry.oldYear = originYear
        let latestEntry = ChangeLogEntry(
            id: UUID(),
            timestamp: oldestEntry.timestamp.addingTimeInterval(1),
            changeType: .yearUpdate,
            trackID: entry.trackID,
            artist: entry.artist,
            trackName: entry.trackName,
            albumName: entry.albumName,
            oldYear: 2019,
            newYear: 2020
        )
        let track = makeTrack(year: 2020)
        try await trackStore.seedMirror([track])
        await bridge.setFetchedTracks([track])
        try await coordinator().recordChanges([oldestEntry, latestEntry])
        return latestEntry
    }

    func observe(year: Int?) async {
        await bridge.setFetchedTracks([makeTrack(year: year)])
    }

    private func makeTrack(year: Int?) -> Track {
        Track(
            id: entry.trackID,
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: year,
            appleScriptID: entry.trackID
        )
    }
}

@Suite("Empty-year undo recovery")
struct YearUndoRecoveryTests {
    @Test("Undoing a year added to an empty field writes the missing-year sentinel")
    func clearsAddedYear() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        let coordinator = fixture.coordinator()

        try await coordinator.revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties == [
            musicUpdate(databaseID: testDatabaseID("T1"), property: .year, value: "0"),
        ])
        #expect(await coordinator.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Legacy zero-year history uses the same empty-year undo")
    func revertsLegacyZero() async throws {
        let fixture = YearUndoFixture()
        var entry = fixture.entry
        entry.oldYear = MusicAppYear.missingValue
        let currentTrack = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019,
            appleScriptID: "T1"
        )
        try await fixture.trackStore.seedMirror([currentTrack])
        await fixture.bridge.setFetchedTracks([currentTrack])
        let coordinator = fixture.coordinator()
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await fixture.bridge.writtenProperties == [
            musicUpdate(databaseID: testDatabaseID("T1"), property: .year, value: "0"),
        ])
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("Unknown write observed as empty finalizes without another dispatch")
    func unknownWriteLanded() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.historyStore.entries == [fixture.entry])

        await fixture.bridge.setCustomWriteError(nil)
        await fixture.observe(year: nil)
        let resumed = fixture.coordinator()
        try await resumed.revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await resumed.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == nil)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == MusicAppYear.missingValue)
    }

    @Test("Unknown write observed at source becomes a fresh retry")
    func unknownWriteMissed() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        await fixture.bridge.setCustomWriteError(nil)

        await expectUndoFailure(
            "Undo did not update track T1; no metadata was changed. Try again",
            matches: { error in
                guard case .undoWriteNotApplied(trackID: "T1") = error else { return false }
                return true
            },
            operation: { try await fixture.coordinator().revertChange(fixture.entry) }
        )
        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.historyStore.entries == [fixture.entry])
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        let retried = fixture.coordinator()
        try await retried.revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties == [
            musicUpdate(databaseID: testDatabaseID("T1"), property: .year, value: "0"),
        ])
        #expect(await retried.getHistory().isEmpty)
    }

    @Test("Unknown write observed at a third value remains blocked")
    func unknownWriteConflicts() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        await fixture.bridge.setCustomWriteError(nil)
        await fixture.observe(year: 2020)

        await expectUndoFailure(
            "Undo recovery for track T1 conflicts with current Music.app state",
            matches: { error in
                guard case .undoRecoveryConflict(trackID: "T1") = error else { return false }
                return true
            },
            operation: { try await fixture.coordinator().revertChange(fixture.entry) }
        )

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.historyStore.entries == [fixture.entry])
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Mirror failure after a landed clear resumes without another dispatch")
    func resumesMirrorFailure() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.trackStore.failAppliedUpdates()

        await expectRecoveryFailure(effects: ["track mirror"]) {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        #expect(await fixture.bridge.writtenProperties.count == 1)
        #expect(await fixture.historyStore.entries == [fixture.entry])
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        await fixture.trackStore.resumeAppliedUpdates()
        let resumed = fixture.coordinator()
        try await resumed.revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties.count == 1)
        #expect(await resumed.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == nil)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == MusicAppYear.missingValue)
    }

    @Test("Normal undo keeps an empty oldest year origin")
    func keepsEmptyOrigin() async throws {
        let fixture = YearUndoFixture()
        let latestEntry = try await fixture.prepareChain(originYear: nil)

        try await fixture.coordinator().revertChange(latestEntry)

        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == 2019)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == 2019)
    }

    @Test("Mirror recovery keeps an empty oldest year origin")
    func recoversEmptyOrigin() async throws {
        let fixture = YearUndoFixture()
        let latestEntry = try await fixture.prepareChain(originYear: nil)
        await fixture.trackStore.failAppliedUpdates()

        await expectRecoveryFailure(effects: ["track mirror"]) {
            try await fixture.coordinator().revertChange(latestEntry)
        }
        await fixture.trackStore.resumeAppliedUpdates()
        try await fixture.coordinator().revertChange(latestEntry)

        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == 2019)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == 2019)
        #expect(await fixture.bridge.writtenProperties.count == 1)
    }

    @Test("Legacy completed checkpoint removes durable history atomically")
    func repairsLegacyCompletedCheckpoint() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let trackStore = TrackDataStore(modelContainer: container)
        let historyStore = ChangeLogDataStore(modelContainer: container)
        try await trackStore.initialize()
        let track = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: nil,
            appleScriptID: "T1"
        )
        try await trackStore.seedMirror([track])
        var historyEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "T1",
            artist: track.artist,
            trackName: track.name,
            albumName: track.album
        )
        historyEntry.oldYear = nil
        historyEntry.newYear = 2019
        try await historyStore.saveEntry(historyEntry)
        var checkpointEntry = ChangeLogEntry(
            changeType: .yearRevert,
            trackID: "T1",
            artist: track.artist,
            trackName: track.name,
            albumName: track.album
        )
        checkpointEntry.oldYear = 2019
        checkpointEntry.newYear = MusicAppYear.missingValue
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCompletedUndo-\(UUID().uuidString)")
        let bridge = MusicAppTestAccess()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
        _ = try await coordinator.backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.completed, historyEntry.id, nil)),
            purpose: .historyUndo,
            effect: "undo recovery checkpoint"
        )
        await coordinator.initialize()

        try await coordinator.revertChange(historyEntry)

        #expect(try await historyStore.loadAll().isEmpty)
        #expect(await bridge.writtenProperties.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory
                .appendingPathComponent("pending-year-revert.json").path))
        let relaunched = UndoCoordinator(
            musicApp: bridge,
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
        await relaunched.initialize()
        #expect(await relaunched.getHistory().isEmpty)
    }

    @Test("Relaunch removes a completed checkpoint after history deletion")
    func removesCompletedOrphan() async throws {
        let fixture = YearUndoFixture()
        var checkpointEntry = ChangeLogEntry(
            changeType: .yearRevert,
            trackID: fixture.entry.trackID,
            artist: fixture.entry.artist,
            trackName: fixture.entry.trackName,
            albumName: fixture.entry.albumName
        )
        checkpointEntry.oldYear = 2019
        checkpointEntry.newYear = MusicAppYear.missingValue
        let coordinator = fixture.coordinator()
        _ = try await coordinator.backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.completed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )

        let relaunched = fixture.coordinator()
        await relaunched.initialize()

        #expect(await relaunched.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("History load failure retains a completed checkpoint")
    func keepsCheckpointWhenHistoryLoadFails() async throws {
        let fixture = YearUndoFixture()
        try await fixture.historyStore.saveEntry(fixture.entry)
        var checkpointEntry = ChangeLogEntry(
            changeType: .yearRevert,
            trackID: fixture.entry.trackID,
            artist: fixture.entry.artist,
            trackName: fixture.entry.trackName,
            albumName: fixture.entry.albumName
        )
        checkpointEntry.oldYear = 2019
        checkpointEntry.newYear = MusicAppYear.missingValue
        let coordinator = fixture.coordinator()
        _ = try await coordinator.backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.completed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )
        await fixture.historyStore.failLoads()

        await fixture.coordinator().initialize()

        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Cancelled history load retries completed cleanup in the same session")
    func retriesHistoryLoadAfterCancellation() async throws {
        let fixture = YearUndoFixture()
        var checkpointEntry = fixture.entry
        checkpointEntry.oldYear = 2019
        checkpointEntry.newYear = MusicAppYear.missingValue
        _ = try await fixture.coordinator().backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.completed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )
        await fixture.historyStore.cancelNextLoad()
        let coordinator = fixture.coordinator()

        await coordinator.initialize()
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        await coordinator.initialize()

        #expect(await coordinator.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.bridge.fetchMetadataCalls().isEmpty)
    }

    @Test("Observation failure reports an unknown undo outcome")
    func reportsObservationFailure() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)
        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        await fixture.bridge.setCustomWriteError(nil)
        await fixture.bridge.setFetchThrowMode(true)

        await expectUndoFailure(
            "Could not verify whether undo updated track T1. Try again after Music.app is available",
            matches: { error in
                guard case .undoOutcomeUnknown(trackID: "T1") = error else { return false }
                return true
            },
            operation: { try await fixture.coordinator().revertChange(fixture.entry) }
        )

        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.historyStore.entries == [fixture.entry])
    }

    @Test("Recovery failure stops older year entries in a batch")
    func recoveryStopsBatch() async throws {
        let fixture = YearUndoFixture()
        _ = try await fixture.prepareChain(originYear: nil)
        let coordinator = fixture.coordinator()
        let entries = await coordinator.getHistory()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await coordinator.revertBatch(entries)
        }
        await fixture.bridge.setCustomWriteError(nil)
        await expectUndoFailure(
            "Undo did not update track T1; no metadata was changed. Try again",
            matches: { error in
                guard case .undoWriteNotApplied(trackID: "T1") = error else { return false }
                return true
            },
            operation: { try await coordinator.revertBatch(entries) }
        )

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await coordinator.getHistory().count == 2)
    }

    @Test("Relaunch repairs an orphaned mirror before cleanup")
    func repairsIncompleteOrphan() async throws {
        let fixture = YearUndoFixture()
        let staleTrack = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2020,
            appleScriptID: "T1"
        )
        try await fixture.trackStore.seedMirror([staleTrack])
        var checkpointEntry = ChangeLogEntry(
            changeType: .yearRevert,
            trackID: fixture.entry.trackID,
            artist: fixture.entry.artist,
            trackName: fixture.entry.trackName,
            albumName: fixture.entry.albumName
        )
        checkpointEntry.oldYear = 2020
        checkpointEntry.newYear = 2019
        let coordinator = fixture.coordinator()
        _ = try await coordinator.backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.changed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )
        var appliedTrack = staleTrack
        appliedTrack.year = 2019
        await fixture.bridge.setFetchedTracks([appliedTrack])

        await fixture.coordinator().initialize()

        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == 2019)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == 2019)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Relaunch resolves orphan recovery from the canonical database ID")
    func usesStoredIDForOrphan() async throws {
        let mapper = TrackIDMapper()
        let fixture = YearUndoFixture(idMapper: mapper, trackID: "AS1")
        let storedTrack = Track(
            id: fixture.entry.trackID,
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2020,
            appleScriptID: "AS1"
        )
        try await fixture.trackStore.seedMirror([storedTrack])
        var checkpointEntry = fixture.entry
        checkpointEntry.oldYear = 2020
        checkpointEntry.newYear = 2019
        _ = try await fixture.coordinator().backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.changed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )
        await fixture.bridge.setFetchedTracks([Track(
            id: "AS1",
            name: storedTrack.name,
            artist: storedTrack.artist,
            album: storedTrack.album,
            year: 2019,
            appleScriptID: "AS1"
        )])

        await fixture.coordinator().initialize()

        let mirrored = try await fixture.trackStore.getTrack(byID: "AS1")
        #expect(mirrored?.year == 2019)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == 2019)
        #expect(try await fixture.bridge.fetchMetadataCalls() == [[#require(MusicDatabaseTrackID(rawValue: "AS1"))]])
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Durable ID lookup cancellation remains retryable")
    func retriesStoredIDAfterCancellation() async throws {
        let mapper = TrackIDMapper()
        let fixture = YearUndoFixture(idMapper: mapper, trackID: "AS1")
        let storedTrack = Track(
            id: fixture.entry.trackID,
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019,
            appleScriptID: "AS1"
        )
        try await fixture.trackStore.seedMirror([storedTrack])
        try await fixture.historyStore.saveEntry(fixture.entry)
        var checkpointEntry = fixture.entry
        checkpointEntry.newYear = MusicAppYear.missingValue
        _ = try await fixture.coordinator().backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.changed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )
        await fixture.trackStore.setReadCancellation(true)
        let coordinator = fixture.coordinator()

        await #expect(throws: CancellationError.self) {
            try await coordinator.revertChange(fixture.entry)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        await fixture.trackStore.setReadCancellation(false)
        await fixture.bridge.setFetchedTracks([Track(
            id: "AS1",
            name: storedTrack.name,
            artist: storedTrack.artist,
            album: storedTrack.album,
            year: nil,
            appleScriptID: "AS1"
        )])
        try await coordinator.revertChange(fixture.entry)

        #expect(await coordinator.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Cancelled startup observation retries in the same session")
    func retriesStartupObservation() async throws {
        let mapper = TrackIDMapper()
        let fixture = YearUndoFixture(idMapper: mapper, trackID: "AS1")
        let storedTrack = Track(
            id: fixture.entry.trackID,
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2020,
            appleScriptID: "AS1"
        )
        try await fixture.trackStore.seedMirror([storedTrack])
        var checkpointEntry = fixture.entry
        checkpointEntry.oldYear = 2020
        checkpointEntry.newYear = 2019
        _ = try await fixture.coordinator().backupCheckpoint(
            for: checkpointEntry.trackID,
            writing: (checkpointEntry, (.changed, fixture.entry.id, MusicAppYear.missingValue)),
            effect: "undo recovery checkpoint"
        )
        await fixture.bridge.setFetchedTracks([Track(
            id: "AS1",
            name: storedTrack.name,
            artist: storedTrack.artist,
            album: storedTrack.album,
            year: 2019,
            appleScriptID: "AS1"
        )])
        await fixture.bridge.setFetchCancellationMode(true)
        let coordinator = fixture.coordinator()

        await coordinator.initialize()
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        await fixture.bridge.setFetchCancellationMode(false)
        await coordinator.initialize()

        let mirrored = try await fixture.trackStore.getTrack(byID: "AS1")
        #expect(mirrored?.year == 2019)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Corrupt undo checkpoint reports a recovery storage failure")
    func reportsCorruptCheckpoint() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fixture.checkpointURL)

        await expectUndoFailure(
            "GenreUpdater could not access undo recovery state for track T1. Retry before making more changes",
            matches: { error in
                guard case .recoveryStorageFailed(trackID: "T1") = error else { return false }
                return true
            },
            operation: { try await fixture.coordinator().revertChange(fixture.entry) }
        )

        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("Checkpoint remove failure reports a recovery storage failure")
    func reportsCheckpointRemoveFailure() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)
        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        await fixture.bridge.setCustomWriteError(nil)
        try Self.setPermissions(0o500, on: fixture.directory)
        defer {
            do {
                try Self.setPermissions(0o700, on: fixture.directory)
            } catch {
                Issue.record("Failed to restore checkpoint directory permissions: \(error)")
            }
        }

        await expectUndoFailure(
            "GenreUpdater could not access undo recovery state for track T1. Retry before making more changes",
            matches: { error in
                guard case .recoveryStorageFailed(trackID: "T1") = error else { return false }
                return true
            },
            operation: { try await fixture.coordinator().revertChange(fixture.entry) }
        )

        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("Mirror recovery keeps the oldest year origin")
    func recoversOldestOrigin() async throws {
        let fixture = YearUndoFixture()
        let latestEntry = try await fixture.prepareChain(originYear: 1998)
        await fixture.trackStore.failAppliedUpdates()

        await expectRecoveryFailure(effects: ["track mirror"]) {
            try await fixture.coordinator().revertChange(latestEntry)
        }
        await fixture.trackStore.resumeAppliedUpdates()
        try await fixture.coordinator().revertChange(latestEntry)

        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == 2019)
        #expect(mirrored?.yearBeforeMGU == 1998)
        #expect(mirrored?.yearSetByMGU == 2019)
        #expect(await fixture.bridge.writtenProperties.count == 1)
    }

    private static let unknownOutcome = AppleScriptOutcomeError(
        scriptName: "update_property",
        reason: "test outcome unknown"
    )

    private static func setPermissions(_ permissions: Int, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    private func expectUnknownOutcome(operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected AppleScript outcome error")
        } catch is AppleScriptOutcomeError {
            // Expected: the checkpoint must resolve the unknown dispatch on retry.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectRecoveryFailure(
        effects expectedEffects: [String],
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected recovery failure")
        } catch let error as UpdateCoordinatorError {
            guard case let .writeFinalizationFailed(trackID, effects) = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
            #expect(trackID == "T1")
            #expect(effects == expectedEffects)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectUndoFailure(
        _ expectedDescription: String,
        matches: (UndoCoordinatorError) -> Bool,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected undo recovery failure")
        } catch let error as UndoCoordinatorError {
            #expect(matches(error))
            #expect(error.localizedDescription == expectedDescription)
        } catch {
            Issue.record("Expected UndoCoordinatorError, got \(error)")
        }
    }
}
