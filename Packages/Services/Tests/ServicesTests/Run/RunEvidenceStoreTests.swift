import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Run evidence persistence")
struct RunEvidenceStoreTests {
    @Test("new current runs reject markerless write evidence")
    func rejectsLegacyEvidenceOnInsert() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = try markerless(makeWorkItem(state: .attempted))
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RunRecordInput(intent: .writeFixes, workItems: [item])
        )

        do {
            try await store.upsert(record)
            Issue.record("Expected markerless current write evidence to be rejected")
        } catch let RunRecordPersistenceError.invalidField(name, runID) {
            #expect(name == "workItems")
            #expect(runID == record.runID.rawValue)
        }
        #expect(try await store.record(for: record.runID) == nil)
    }

    @Test("relaunch rejects a current terminal parent that loses write evidence")
    func rejectsLostTerminal() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = makeWorkItem(state: .outcome(.written))
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(intent: .writeFixes, workItems: [item])
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>()).first)
        var payload = try #require(
            try JSONSerialization.jsonObject(with: row.transitionsData) as? [String: Any]
        )
        var workItems = try #require(payload["workItems"] as? [[String: Any]])
        workItems[0].removeValue(forKey: "writeChange")
        workItems[0].removeValue(forKey: "writeEvidenceVersion")
        workItems[0].removeValue(forKey: "hasWriteEvidence")
        payload["workItems"] = workItems
        row.transitionsData = try JSONSerialization.data(withJSONObject: payload)
        try context.save()

        do {
            _ = try await RunRecordDataStore(modelContainer: container).record(for: record.runID)
            Issue.record("Expected missing terminal write evidence to be rejected")
        } catch let RunRecordPersistenceError.corruptedField(name, runID) {
            #expect(name == "workItems")
            #expect(runID == record.runID.rawValue)
        }
    }
}

private func markerless(_ item: RunWorkItem) throws -> RunWorkItem {
    var payload = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
    )
    payload.removeValue(forKey: "writeChange")
    payload.removeValue(forKey: "writeEvidenceVersion")
    payload.removeValue(forKey: "hasWriteEvidence")
    return try JSONDecoder().decode(
        RunWorkItem.self,
        from: JSONSerialization.data(withJSONObject: payload)
    )
}
