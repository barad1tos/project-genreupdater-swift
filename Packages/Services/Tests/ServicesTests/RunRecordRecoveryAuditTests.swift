import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run record recovery audit")
struct RunRecordRecoveryAuditTests {
    @Test("relaunch rejects a child row that injects a dismissal stamp")
    func rejectsInjectedDismissal() async throws {
        let fixture = try await makeRecoverableNoOpFixture()
        try mutateChild(in: fixture.container) { payload in
            payload["dismissedAt"] = Date(timeIntervalSince1970: 500).timeIntervalSinceReferenceDate
        }

        await #expect(throws: RunRecordPersistenceError.self) {
            _ = try await RunRecordDataStore(modelContainer: fixture.container).record(for: fixture.record.runID)
        }
    }

    @Test("relaunch rejects a child row that injects a recovery blocker")
    func rejectsInjectedRecoveryBlocker() async throws {
        let fixture = try await makeRecoverableNoOpFixture()
        try mutateChild(in: fixture.container) { payload in
            payload["recoveryObservationIssue"] = RecoveryObservationIssue.trackMissing.rawValue
        }

        await #expect(throws: RunRecordPersistenceError.self) {
            _ = try await RunRecordDataStore(modelContainer: fixture.container).record(for: fixture.record.runID)
        }
    }

    @Test("recovery blocker and acknowledgement rows round-trip when parent and child agree")
    func recoveryAuditRowsRoundTrip() async throws {
        let fixture = try await makeRecoverableNoOpFixture()
        let item = try #require(fixture.record.workItems.first)
        let blocked = try fixture.record.recordingRecoveryObservationBlocker(
            RecoveryObservationBlocker(itemID: item.id, issue: .trackMissing)
        )
        try await fixture.store.upsert(blocked)
        #expect(try await fixture.store.record(for: blocked.runID) == blocked)

        let acknowledged = try blocked.dismissingUncertainWork(
            id: item.id,
            reason: "track removed",
            at: Date(timeIntervalSince1970: 500)
        )
        try await fixture.store.upsert(acknowledged)
        #expect(try await fixture.store.record(for: acknowledged.runID) == acknowledged)
    }

    private func makeRecoverableNoOpFixture() async throws -> (
        container: ModelContainer,
        store: RunRecordDataStore,
        record: RunRecord
    ) {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = makeWorkItem(state: .outcome(.noFixNeeded))
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                recoveryID: UUID(),
                workItems: [item],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)
        return (container, store, record)
    }

    private func mutateChild(
        in container: ModelContainer,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunWorkItem>()).first)
        var payload = try #require(
            try JSONSerialization.jsonObject(with: row.itemData) as? [String: Any]
        )
        mutation(&payload)
        row.itemData = try JSONSerialization.data(withJSONObject: payload)
        try context.save()
    }
}
