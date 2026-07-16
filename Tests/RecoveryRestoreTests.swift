import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Recovery restore")
@MainActor
struct RecoveryRestoreTests {
    @Test(
        "Interrupted writes restore a durable hold",
        arguments: [
            RunLifecycleState.writing,
            .verifying,
            .reporting,
            .blocked,
            .recoverable,
            .recovering,
        ]
    )
    func restoresInterruptedWrite(state: RunLifecycleState) async throws {
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let record = sampleRunRecord(
            intent: .writeFixes,
            state: state,
            failureMessage: "Write interrupted",
            finishedAt: nil
        )
        try await setup.store.upsert(record)

        #expect(await setup.dependencies.ensureRecoveryHold())

        let recoveryID = try #require(await setup.processor.recoveryHoldID())
        let restored = try #require(await setup.store.record(for: record.runID))
        #expect(restored.state == (state == .blocked ? .blocked : .recoverable))
        #expect(restored.recoveryID == recoveryID)
        #expect(restored.failureMessage == "Write interrupted")
    }

    @Test("Corrupted interrupted write restores a fail-closed hold")
    func restoresCorruptedWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(id: runID, state: .recoverable, into: container)

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() == runID)
    }

    @Test("Store failures create a fail-closed batch hold")
    func storeFailureHolds() async throws {
        let setup = try makeRecoverySetup(
            store: RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile))
        )
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() != nil)
    }

    @Test("Recovery claim failures create a fail-closed batch hold")
    func claimFailureHolds() async throws {
        let record = sampleRunRecord(
            intent: .writeFixes,
            state: .writing,
            finishedAt: nil
        )
        let setup = try makeRecoverySetup(store: RunRecordStoreStub(
            claimError: CocoaError(.fileWriteUnknown),
            storedRecord: record,
            reportPage: RunReportPage(records: [record], skippedCorruptedCount: 0)
        ))
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() != nil)
    }
}
