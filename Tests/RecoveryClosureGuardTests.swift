import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Recovery closure guards")
@MainActor
struct RecoveryClosureGuardTests {
    @Test("An unbound legacy no-op cannot close through the hold-only path")
    func unboundLegacyNoOpKeepsHold() async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: nil,
            itemState: .outcome(.noFixNeeded),
            oldValue: nil,
            newValue: "1970",
            changeType: .yearUpdate
        )
        try await setup.store.upsert(record)

        await #expect(throws: WorkCheckpointError.self) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        let retained = try #require(await setup.store.record(for: record.runID))
        #expect(retained.finishedAt == nil)
        #expect(retained.workItems.first?.state == .outcome(.noFixNeeded))
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }
}
