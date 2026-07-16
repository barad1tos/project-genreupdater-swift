import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Recovery clear")
@MainActor
struct RecoveryClearTests {
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

    @Test("Verified corrupted write becomes a readable audit record")
    func closesCorruptedWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(id: runID, state: .recoverable, into: container)
        #expect(await setup.dependencies.ensureRecoveryHold())

        try await setup.dependencies.clearRecoveryHold(id: runID)

        #expect(await setup.processor.recoveryHoldID() == nil)
        #expect(await setup.dependencies.ensureRecoveryHold() == false)
        let audit = try #require(await store.reports(matching: RunReportQuery()).records.first)
        #expect(audit.state == .cancelled)
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
}
