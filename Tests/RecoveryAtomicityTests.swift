import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Recovery atomicity")
@MainActor
struct RecoveryAtomicityTests {
    @Test("Recovery retry does not advance a mirror-only finalization twice")
    func mirrorOnlyRetryIsIdempotent() async throws {
        let recoveryID = UUID()
        let writeChange = WorkChange(
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 90,
            source: "Library"
        )
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: "Rock",
            newValue: "Metal",
            writeChange: writeChange
        )
        let baseStore = try RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())
        try await baseStore.upsert(record)
        let failingStore = FlakyRecoveryStore(base: baseStore, failingUpserts: 1)
        let setup = try await makeRecoverySetup(store: failingStore)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        _ = await setup.processor.beginRecoveryHold(id: recoveryID)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            appleScriptID: "persistent-1"
        )])
        let reopened = try #require(await baseStore.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

        await #expect(throws: FlakyRecoveryStore.StoreDown.self) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }
        let firstRevision = try await setup.trackStore.loadMirrorSnapshot().revision
        #expect(firstRevision == MirrorRevision(value: 2))
        #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.genre == "Metal")

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        #expect(try await setup.trackStore.loadMirrorSnapshot().revision == firstRevision)
        #expect(try await baseStore.record(for: record.runID)?.finishedAt != nil)
        #expect(await setup.processor.recoveryHoldID() == nil)
    }

    @Test("Acknowledgement during observation prevents stale mirror repair")
    func acknowledgementWinsDuringObservation() async throws {
        let recoveryID = UUID()
        let (record, item) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: nil,
            newValue: "1970",
            changeType: .yearUpdate
        )
        let blocked = try record.recordingRecoveryObservationBlocker(
            RecoveryObservationBlocker(itemID: item.id, issue: .trackMissing)
        )
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        _ = await setup.processor.beginRecoveryHold(id: recoveryID)
        try await setup.store.upsert(blocked)
        try await setup.trackStore.seedMirror([Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: 2001,
            appleScriptID: "persistent-1"
        )])
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        let verifier = SuspendedRecoveryVerifier(tracks: [Track(
            id: "persistent-1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: 1970,
            appleScriptID: "persistent-1"
        )])
        setup.dependencies.recoveryVerifier = verifier
        await setup.dependencies.runOrchestrator?.restoreRecovery(blocked)

        let clearance = Task { @MainActor in
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }
        await verifier.waitUntilEntered()
        try await setup.dependencies.dismissRecoveryWork(
            id: recoveryID,
            itemIDs: [item.id],
            reason: "track removed",
            isIndividual: true
        )
        await verifier.release()
        await #expect(throws: AppDependencyServiceError.recoveryUnavailable) {
            try await clearance.value
        }

        #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
        let acknowledged = try #require(await setup.store.record(for: record.runID))
        #expect(acknowledged.workItems.first?.dismissedAt != nil)
        #expect(acknowledged.workItems.first?.recoveryObservationIssue == nil)

        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
        #expect(try await setup.store.record(for: record.runID)?.finishedAt != nil)
        #expect(await setup.processor.recoveryHoldID() == nil)
    }
}
