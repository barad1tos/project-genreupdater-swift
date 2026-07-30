import Core
import Foundation
import Services
import SwiftData
import Testing
@testable import Genre_Updater

@Suite("Recovery clear")
@MainActor
struct RecoveryClearTests {
    @Test("Observed clearance closes uncertain work with physical outcomes")
    func observedClearanceClosesUncertainRun() async throws {
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.installTestObservationClient(RecoveryScriptStub(tracks: [
            Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                genre: "Stoner Rock"
            ),
        ]))
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
    }

    @Test("Observed clearance repairs missing undo history for landed writes")
    func observedClearanceRepairsHistory() async throws {
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.installTestObservationClient(RecoveryScriptStub(tracks: [
            Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                genre: "Stoner Rock"
            ),
        ]))
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
    }

    @Test("Checkpointed terminal writes repair history without observation")
    func terminalWrittenRepairsHistory() async throws {
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.written)
        )
        try await setup.store.upsert(record)
        try await setup.trackStore.saveTracks([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Stoner Rock"
        )])
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        let durable = try await setup.changeLog.loadAll()
        #expect(durable.map(\.newGenre) == ["Stoner Rock"])
        let persisted = try ModelContext(setup.persistenceContainer)
            .fetch(FetchDescriptor<PersistedTrack>())
        #expect(persisted.map(\.genreUpdated) == [true])
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Blocked availability keeps the hold with an actionable reason")
    func blockedAvailabilityKeepsHold() async throws {
        let setup = try makeRecoverySetup()
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
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, item) = uncertainRunRecord(recoveryID: recoveryID, itemState: .prepared)
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { false },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.installTestObservationClient(RecoveryScriptStub(tracks: []))
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
        let setup = try makeRecoverySetup()
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

    @Test("Clearance without observation keeps the uncertain record open")
    func blindClearanceKeepsUncertainRecordOpen() async throws {
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await setup.store.upsert(record)
        let stored = try #require(await setup.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(stored)

        await #expect(throws: AppDependencyServiceError.recoveryVerificationFailed) {
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
        let setup = try makeRecoverySetup(store: flaky)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = UUID()
        let (record, _) = uncertainRunRecord(recoveryID: recoveryID)
        try await realStore.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.installTestObservationClient(RecoveryScriptStub(tracks: []))

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
        let setup = try makeRecoverySetup(store: flaky)
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

    @Test("Verified write closes its run and releases every hold")
    func closesVerifiedWrite() async throws {
        let setup = try makeRecoverySetup()
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
        let setup = try makeRecoverySetup(store: store)
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
        let setup = try makeRecoverySetup()
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
        let setup = try makeRecoverySetup(store: RunRecordDataStore(modelContainer: container))
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
        let setup = try makeRecoverySetup(store: RunRecordDataStore(modelContainer: container))
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
