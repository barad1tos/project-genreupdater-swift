import Core
import Foundation
import SwiftData
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Recovery clear")
@MainActor
struct RecoveryClearTests {
    @Test("Observed clearance closes uncertain work with physical outcomes")
    func observedClearanceClosesUncertainRun() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [
            Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                genre: "Stoner Rock",
                appleScriptID: "persistent-1"
            ),
        ])
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let closed = try #require(await setup.store.record(for: record.runID))
        #expect(closed.state == .cancelled)
        #expect(closed.finishedAt != nil)
        #expect(closed.workItems.map(\.state) == [.outcome(.written)])
        #expect(closed.workItems.first?.id == item.id)
        #expect(closed.workItems.first?.detail == "Verified in Music.app: Stoner Rock")
        #expect(await setup.processor.recoveryHoldID() == nil)
        let mirrored = try #require(try await setup.trackStore.getTrack(byID: "persistent-1"))
        #expect(mirrored.genre == "Stoner Rock")
        let persisted = try ModelContext(setup.persistenceContainer)
            .fetch(FetchDescriptor<PersistedTrack>())
        #expect(persisted.map(\.genreUpdated) == [true])
    }

    @Test("Observed clearance repairs missing undo history for landed writes")
    func observedClearanceRepairsHistory() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [
            Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                genre: "Stoner Rock",
                appleScriptID: "persistent-1"
            ),
        ])
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)
        #expect(await setup.undo.getHistory().isEmpty)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let history = await setup.undo.getHistory()
        #expect(history.map(\.trackID) == ["persistent-1"])
        #expect(history.first?.changeType == .genreUpdate)
        #expect(history.first?.newGenre == "Stoner Rock")
        let durable = try await setup.changeLog.loadAll()
        #expect(durable.map(\.trackID) == ["persistent-1"])
        // Repaired evidence must attribute to the repaired run, or the entry
        // becomes a permanent nil-runID row that run retention never prunes.
        #expect(durable.first?.runID == record.runID.rawValue)
    }

    @Test("Reopened recovery repairs only the reconciled artist effect")
    func repairsRelaunchedArtist() async throws {
        let recoveryID = UUID()
        let writeChange = WorkChange(
            changeType: .artistRename,
            oldValue: "Artist",
            newValue: "Renamed Artist",
            confidence: 90,
            source: "Library"
        )
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            oldValue: "Artist",
            newValue: "Renamed Artist",
            changeType: .artistRename,
            albumArtist: RecoveryAlbumArtistFixture(
                capturedValue: "Various Artists",
                change: AlbumArtistChange(
                    oldValue: "Artist",
                    newValue: "Renamed Artist"
                )
            ),
            writeChange: writeChange
        )
        let relaunch = try await makeRelaunchedStore(seeding: record)
        defer { try? FileManager.default.removeItem(at: relaunch.directory) }
        let setup = try await makeArtistRecovery(store: relaunch.store, recoveryID: recoveryID)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let reopened = try #require(await relaunch.store.record(for: record.runID))
        #expect(reopened.workItems.first?.writeChange == writeChange)
        await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let closed = try #require(await relaunch.store.record(for: record.runID))
        #expect(closed.workItems.map(\.state) == [.outcome(.written)])
        let durable = try await setup.changeLog.loadAll()
        #expect(durable.count == 1)
        #expect(durable.first?.oldArtist == "Artist")
        #expect(durable.first?.newArtist == "Renamed Artist")
        #expect(durable.first?.albumArtistChange == nil)
        #expect(durable.first?.runID == record.runID.rawValue)
        #expect(await setup.undo.getHistory() == durable)
        let mirrored = try #require(try await setup.trackStore.getTrack(byID: "persistent-1"))
        #expect(mirrored.artist == "Renamed Artist")
        #expect(mirrored.albumArtist == "Various Artists")
        let report = RunReportDetailBuilder.makeDetail(from: closed, now: Date())
        #expect(report.workItems.map(\.changeLabel) == [
            "Artist: Artist → Renamed Artist — Track",
        ])
        #expect(report.workItems.allSatisfy { !$0.changeLabel.localizedCaseInsensitiveContains("album artist") })
    }

    @Test("Clearance fails closed when the undo coordinator is missing")
    func clearanceFailsClosedWithoutUndoCoordinator() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        // Drop the coordinator that owns durable change history: the written
        // item's evidence can no longer be rebuilt.
        setup.dependencies.installTestWrites(TestWriteServices(
            batchProcessor: setup.processor,
            undoCoordinator: nil,
            runRecordStore: setup.store
        ))

        await #expect(throws: AppDependencyServiceError.self) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        // Clearing a hold whose evidence was never repaired would report a
        // verified close over missing history, so the hold has to survive.
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
        #expect(try await setup.changeLog.loadAll().isEmpty)
    }

    @Test("Checkpointed terminal writes repair history without observation")
    func terminalWrittenRepairsHistory() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let durable = try await setup.changeLog.loadAll()
        #expect(durable.map(\.newGenre) == ["Stoner Rock"])
        #expect(durable.first?.runID == record.runID.rawValue)
        let persisted = try ModelContext(setup.persistenceContainer)
            .fetch(FetchDescriptor<PersistedTrack>())
        #expect(persisted.map(\.trackID) == ["persistent-1"])
        #expect(persisted.map(\.genre) == ["Stoner Rock"])
        #expect(persisted.map(\.genreUpdated) == [true])
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Checkpointed no-op repairs the mirror without creating undo history")
    func terminalNoOpRepairsMirror() async throws {
        let recoveryID = UUID()
        let writeChange = WorkChange(
            changeType: .artistRename,
            oldValue: "Artist",
            newValue: "Renamed Artist",
            confidence: 90,
            source: "Library"
        )
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: "Artist",
            newValue: "Renamed Artist",
            changeType: .artistRename,
            albumArtist: RecoveryAlbumArtistFixture(
                capturedValue: "Various Artists",
                change: AlbumArtistChange(
                    oldValue: "Artist",
                    newValue: "Renamed Artist"
                )
            ),
            writeChange: writeChange
        )
        let relaunch = try await makeRelaunchedStore(seeding: record)
        defer { try? FileManager.default.removeItem(at: relaunch.directory) }
        let setup = try await makeArtistRecovery(store: relaunch.store, recoveryID: recoveryID)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let reopened = try #require(await relaunch.store.record(for: record.runID))
        #expect(reopened.workItems.first?.writeChange == writeChange)
        await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let mirrored = try #require(try await setup.trackStore.getTrack(byID: "persistent-1"))
        #expect(mirrored.artist == "Renamed Artist")
        #expect(mirrored.albumArtist == "Various Artists")
        #expect(mirrored.appleScriptID == "persistent-1")
        #expect(try await setup.changeLog.loadAll().isEmpty)
        #expect(await setup.undo.getHistory().isEmpty)
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Recovery preserves canonical AppleScript history identity")
    func preservesCanonicalHistory() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        let legacyID = UUID()
        var legacy = ChangeLogEntry(
            id: legacyID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_001),
            changeType: .genreUpdate,
            trackID: "persistent-1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album",
            oldGenre: "Rock",
            newGenre: "Stoner Rock"
        )
        legacy.runID = record.runID.rawValue
        try await setup.changeLog.saveEntry(legacy)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let durable = try await setup.changeLog.loadAll()
        #expect(durable.count == 1)
        #expect(durable.first?.id == legacyID)
        #expect(durable.first?.trackID == "persistent-1")
        #expect(durable.first?.runID == record.runID.rawValue)
        #expect(await setup.undo.getHistory().map(\.trackID) == ["persistent-1"])
    }

    @Test("Recovery retry reuses migrated history after mirror failure")
    func retriesPartialRepair() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        let legacyID = UUID()
        var legacy = ChangeLogEntry(
            id: legacyID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_001),
            changeType: .genreUpdate,
            trackID: "persistent-1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album",
            oldGenre: "Rock",
            newGenre: "Stoner Rock"
        )
        legacy.runID = record.runID.rawValue
        try await setup.changeLog.saveEntry(legacy)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        await #expect(throws: TrackStoreError.self) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
        var durable = try await setup.changeLog.loadAll()
        #expect(durable.count == 1)
        #expect(durable.first?.id == legacyID)
        #expect(durable.first?.trackID == "persistent-1")

        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        durable = try await setup.changeLog.loadAll()
        #expect(durable.count == 1)
        #expect(durable.first?.id == legacyID)
        #expect(await setup.undo.getHistory().map(\.trackID) == ["persistent-1"])
        #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.genre == "Stoner Rock")
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Recovery replaces phantom in-memory history with durable evidence")
    func replacesPhantomHistory() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        var phantom = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "persistent-1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        phantom.oldGenre = "Rock"
        phantom.newGenre = "Stoner Rock"
        phantom.runID = record.runID.rawValue
        await setup.changeLog.failSaves()
        await #expect(throws: RecoveryChangeLogStore.SaveFailure.self) {
            try await setup.undo.recordChange(phantom)
        }
        #expect(await setup.undo.getHistory().map(\.id) == [phantom.id])
        #expect(try await setup.changeLog.loadAll().isEmpty)
        await setup.changeLog.resumeSaves()
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let durable = try await setup.changeLog.loadAll()
        #expect(durable.count == 1)
        #expect(durable.first?.trackID == "persistent-1")
        #expect(durable.first?.runID == record.runID.rawValue)
        #expect(await setup.undo.getHistory().count == 1)
        #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.genre == "Stoner Rock")
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Recovery keeps the hold when durable history cannot be read")
    func rejectsUnreadableHistory() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)
        await setup.changeLog.failReads()

        await #expect(throws: RecoveryChangeLogStore.ReadFailure.self) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        #expect(await setup.processor.recoveryHoldID() == recoveryID)
        let retained = try #require(await setup.store.record(for: record.runID))
        #expect(retained.finishedAt == nil)
        await setup.changeLog.resumeReads()
        #expect(try await setup.changeLog.loadAll().isEmpty)
    }

    @Test("Blocked availability keeps the hold with an actionable reason")
    func blockedAvailabilityKeepsHold() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { false },
            areScriptsInstalled: { true }
        )))
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        await #expect(throws: AppDependencyServiceError.recoveryObservationBlocked(.musicAppUnavailable)) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        let retained = try #require(await setup.store.record(for: record.runID))
        #expect(retained.finishedAt == nil)
        #expect(retained.workItems.map(\.state) == [.attempted])
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Prepared-only records clear locally while Music.app is closed")
    func preparedOnlyClearsWhileBlocked() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID, itemState: .prepared)
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { false },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [])
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let closed = try #require(await setup.store.record(for: record.runID))
        #expect(closed.finishedAt != nil)
        #expect(closed.workItems.map(\.state) == [.outcome(.skipped)])
        #expect(closed.workItems.first?.id == item.id)
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Preflight reports the blocker for uncertain records")
    func preflightReportsBlocker() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { false },
            areScriptsInstalled: { true }
        )))

        let outcome = await setup.dependencies.runRecoveryPreflight(runID: record.runID)

        guard case .blocked(record.runID, .musicAppUnavailable) = outcome else {
            Issue.record("Expected a musicAppUnavailable blocker, got \(outcome)")
            return
        }
    }

    @Test("Clearance without an observation client reports the unavailable observation")
    func unavailableObservationKeepsUncertainRecordOpen() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        await #expect(throws: AppDependencyServiceError.recoveryObservationNeedsAttention(.observationUnavailable)) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        let retained = try #require(await setup.store.record(for: record.runID))
        #expect(retained.finishedAt == nil)
        #expect(retained.workItems.map(\.state) == [.attempted])
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Repeated store failures reuse one synthetic hold and yield to the real one")
    func syntheticHoldStaysStable() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let realStore = RunRecordDataStore(modelContainer: container)
        let flaky = FlakyRecoveryStore(base: realStore, failingReads: 2)
        let setup = try await makeRecoverySetup(store: flaky)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = UUID()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await realStore.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [])

        #expect(await setup.dependencies.ensureRecoveryHold())
        let firstHold = await setup.processor.recoveryHoldID()
        #expect(firstHold == SyntheticRecoveryHold.id)
        #expect(await setup.dependencies.ensureRecoveryHold())
        #expect(await setup.processor.recoveryHoldID() == firstHold)

        try? await setup.dependencies.clearRecoveryHold(id: SyntheticRecoveryHold.id)

        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Synthetic hold identity never persists onto an unclaimed record")
    func syntheticHoldNeverClaimsRecords() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let realStore = RunRecordDataStore(modelContainer: container)
        let flaky = FlakyRecoveryStore(base: realStore, failingReads: 1)
        let setup = try await makeRecoverySetup(store: flaky)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let (record, _) = uncertainRunRecord(recoveryID: nil)
        try await realStore.upsert(record)

        #expect(await setup.dependencies.ensureRecoveryHold())
        #expect(await setup.processor.recoveryHoldID() == SyntheticRecoveryHold.id)
        #expect(await setup.dependencies.ensureRecoveryHold())

        let claimed = try #require(await realStore.record(for: record.runID))
        let claimedID = try #require(claimed.recoveryID)
        #expect(claimedID != SyntheticRecoveryHold.id)
    }

    @Test("Dismissal resolves the record by run ID as well as hold ID")
    func dismissalResolvesByRunID() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID, itemState: .prepared)
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        // The navigation surface carries run IDs, not hold IDs.
        try await setup.dependencies.dismissRecoveryWork(
            id: record.runID.rawValue,
            itemIDs: [item.id],
            reason: "duplicate",
            isIndividual: false
        )

        let persisted = try #require(await setup.store.record(for: record.runID))
        #expect(persisted.workItems.first?.state == .outcome(.dismissed))
    }

    @Test("Grouped dismissal persists selected closures and keeps the hold")
    func groupedDismissalPersistsAndKeepsHold() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID, itemState: .prepared)
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.dismissRecoveryWork(
            id: recoveryID,
            itemIDs: [item.id],
            reason: "duplicate",
            isIndividual: false
        )

        let persisted = try #require(await setup.store.record(for: record.runID))
        #expect(persisted.workItems.first?.state == .outcome(.dismissed))
        #expect(persisted.workItems.first?.dismissedAt != nil)
        #expect(persisted.finishedAt == nil)
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Grouped dismissal refuses write-uncertain selections")
    func groupedDismissalRefusesUncertain() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID, itemState: .attempted)
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        await #expect(throws: WorkCheckpointError.self) {
            try await setup.dependencies.dismissRecoveryWork(
                id: recoveryID,
                itemIDs: [item.id],
                reason: "cleanup",
                isIndividual: false
            )
        }

        let persisted = try #require(await setup.store.record(for: record.runID))
        #expect(persisted.workItems.first?.state == .attempted)
    }

    @Test("Individual dismissal closes an uncertain item as an explicit decision")
    func individualDismissalClosesUncertain() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID, itemState: .attempted)
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.dismissRecoveryWork(
            id: recoveryID,
            itemIDs: [item.id],
            reason: "checked manually",
            isIndividual: true
        )

        let persisted = try #require(await setup.store.record(for: record.runID))
        #expect(persisted.workItems.first?.state == .outcome(.dismissed))
        #expect(persisted.workItems.first?.detail?.contains("without verification") == true)
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Verified write closes its run and releases every hold")
    func closesVerifiedWrite() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let record = sampleRunRecord(
            intent: .writeFixes,
            state: .recoverable,
            recoveryID: recoveryID,
            failureMessage: "Unknown write outcome",
            finishedAt: nil
        )
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let closed = try #require(await setup.store.record(for: record.runID))
        #expect(closed.state == .cancelled)
        #expect(closed.finishedAt != nil)
        #expect(closed.transitions.suffix(2).map(\.state) == [.recovering, .cancelled])
        #expect(await setup.processor.recoveryHoldID() == nil)
        #expect(await setup.dependencies.ensureRecoveryHold() == false)
    }

    @Test("Opaque writes cannot be dismissed after verification")
    func holdsOpaqueWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try await makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(id: runID, state: .recoverable, into: container)
        #expect(await setup.dependencies.ensureRecoveryHold())

        await #expect(throws: AppDependencyServiceError.recoveryBlocked) {
            try await setup.dependencies.clearRecoveryHold(id: runID)
        }

        #expect(await setup.processor.recoveryHoldID() == runID)
        let page = try await store.reports(matching: RunReportQuery())
        #expect(page.records.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Blocked recovery cannot be dismissed as verified")
    func blockedRecoveryStaysOpen() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let record = sampleRunRecord(intent: .writeFixes, state: .blocked, finishedAt: nil)
        try await setup.store.upsert(record)
        #expect(await setup.dependencies.ensureRecoveryHold())
        let recoveryID = try #require(await setup.processor.recoveryHoldID())

        await #expect(throws: AppDependencyServiceError.recoveryBlocked) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        #expect(try await setup.store.record(for: record.runID)?.state == .blocked)
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Future recovery payload requires an app update")
    func futurePayloadNeedsUpdate() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let setup = try await makeRecoverySetup(store: RunRecordDataStore(modelContainer: container))
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(
            id: runID,
            state: .recoverable,
            transitionsData: JSONEncoder().encode(FutureRecoveryPayload()),
            into: container
        )
        #expect(await setup.dependencies.ensureRecoveryHold())
        #expect(await setup.dependencies.runRecoveryPreflight(runID: RunID(rawValue: runID)) == .needsAttention(
            runID: RunID(rawValue: runID),
            reason: .unsupportedPayload
        ))

        await #expect(throws: AppDependencyServiceError.recoveryUpdateRequired) {
            try await setup.dependencies.clearRecoveryHold(id: runID)
        }

        #expect(await setup.processor.recoveryHoldID() == runID)
    }

    @Test("Corrupted blocked write cannot be dismissed")
    func blockedWriteStaysOpen() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let setup = try await makeRecoverySetup(store: RunRecordDataStore(modelContainer: container))
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(id: runID, state: .blocked, into: container)
        #expect(await setup.dependencies.ensureRecoveryHold())
        #expect(await setup.dependencies.runRecoveryPreflight(runID: RunID(rawValue: runID)) == .needsAttention(
            runID: RunID(rawValue: runID),
            reason: .unresolvedState(.blocked)
        ))

        await #expect(throws: AppDependencyServiceError.recoveryBlocked) {
            try await setup.dependencies.clearRecoveryHold(id: runID)
        }

        #expect(await setup.processor.recoveryHoldID() == runID)
    }
}

private struct FutureRecoveryPayload: Encodable {
    let version = Int.max
}
