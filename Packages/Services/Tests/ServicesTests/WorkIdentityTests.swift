import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Work item identity", .serialized)
struct WorkIdentityTests {
    @Test("Full persistence rejects duplicate identities")
    func rejectsDuplicateWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let record = duplicateRecord(startedAt: Date(timeIntervalSince1970: 100))

        do {
            try await store.upsert(record)
            Issue.record("Expected duplicate work identities to be rejected")
        } catch let RunRecordPersistenceError.invalidField(name, runID) {
            #expect(name == "workItems")
            #expect(runID == record.runID.rawValue)
        }

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<PersistedRunRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistedRunWorkItem>()).isEmpty)
    }

    @Test("Persisted duplicates require attention and survive retention")
    func holdsDuplicateAudit() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let duplicate = duplicateRecord(startedAt: Date(timeIntervalSince1970: 100))
        let context = ModelContext(container)
        try context.insert(PersistedRunRecord(
            record: duplicate,
            scopeData: JSONEncoder().encode(duplicate.scope),
            payloadData: JSONEncoder().encode(RunRecordPayload(record: duplicate))
        ))
        try context.save()
        let store = RunRecordDataStore(modelContainer: container)

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.record(for: duplicate.runID)
        }
        let page = try await store.reports(matching: RunReportQuery())
        #expect(page.corruptedRunIDs == [duplicate.runID])
        #expect(page.attentionRunIDs == [duplicate.runID])
        #expect(page.closableRunIDs.isEmpty)
        #expect(try await store.closeCorruptedRun(duplicate.runID, at: Date()) == false)
        #expect(try await store.closeReadOnlyCorruption(duplicate.runID, at: Date()) == false)

        let valid = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completedNoOp,
            syncSummary: nil
        )
        try await store.upsert(valid)

        #expect(try await store.prune(keepingLatest: 1) == 0)
        let runIDs = try ModelContext(container)
            .fetch(FetchDescriptor<PersistedRunRecord>())
            .map(\.runID)
        #expect(Set(runIDs) == [duplicate.runID.rawValue, valid.runID.rawValue])
    }
}

private func duplicateRecord(startedAt: Date) -> RunRecord {
    let itemID = UUID()
    return makeRunRecord(
        startedAt: startedAt,
        finishedAt: startedAt.addingTimeInterval(1),
        state: .completed,
        syncSummary: nil,
        input: RunRecordInput(
            intent: .writeFixes,
            workItems: [
                makeWorkItem(id: itemID, state: .outcome(.written)),
                makeWorkItem(id: itemID, state: .outcome(.failed)),
            ],
            includesSyncTransition: false
        )
    )
}
