import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Work item repair", .serialized)
struct WorkItemRepairTests {
    @Test("Truncated current payload keeps its item audit", arguments: PayloadTruncation.allCases)
    func holdsTruncatedAudit(_ truncation: PayloadTruncation) async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        var storedData = try JSONEncoder().encode(ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: repairTransitions(),
            workItems: [makeWorkItem(state: .attempted)],
            configuration: makeRunConfiguration(
                scopeID: scope.id,
                capturedAt: startedAt,
                writeAuthority: .reviewedPlan
            )
        ))
        switch truncation {
        case .prefix:
            storedData.removeFirst()
        case .suffix:
            storedData.removeLast()
        }
        try insertRunRow(
            runID: runID,
            transitionsData: storedData,
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: startedAt)

        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(didClose == false)
        #expect(rows.first?.transitionsData == storedData)
    }

    @Test("Successful repair preserves work-item outcomes")
    func preservesRepairAudit() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let workItems = [
            makeWorkItem(state: .outcome(.written)),
            makeWorkItem(state: .outcome(.failed))
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: repairTransitions(),
                workItems: workItems,
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                rawIntent: "invalid",
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())
        let repaired = try #require(await store.record(for: RunID(rawValue: runID)))

        #expect(didClose)
        #expect(repaired.workItems == workItems)
        #expect(repaired.state == .cancelled)
    }

    @Test("Repair preserves a malformed child audit for attention")
    func holdsMalformedChild() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = makeWorkItem(state: .attempted)
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        let child = try #require(context.fetch(FetchDescriptor<PersistedRunWorkItem>()).first)
        child.itemData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try context.save()

        let didClose = try await store.closeCorruptedRun(
            record.runID,
            at: Date(timeIntervalSince1970: 200)
        )
        let page = try await store.recoveryRecords()
        let remainingChildren = try ModelContext(container).fetch(FetchDescriptor<PersistedRunWorkItem>())

        #expect(didClose == false)
        #expect(page.attentionRunIDs == [record.runID])
        #expect(remainingChildren.count == 1)
    }

    @Test("Terminal repair preserves work-item outcomes")
    func preservesTerminalAudit() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 101)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let workItems = [makeWorkItem(state: .outcome(.written))]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .completed, timestamp: finishedAt)
                ],
                workItems: workItems,
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .completed,
                startedAt: startedAt
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: startedAt)
        let repaired = try #require(await store.record(for: RunID(rawValue: runID)))

        #expect(didClose)
        #expect(repaired.workItems == workItems)
        #expect(repaired.finishedAt == finishedAt)
    }

    @Test("Terminal repair holds conflicting parent and child outcomes for attention")
    func holdsOutcomeConflict() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 101)
        let item = makeWorkItem(state: .prepared)
        let attempting = try item.transition(to: .attempting)
        let attempted = try attempting.transition(to: .attempted)
        let parentItem = try attempted.transition(to: .outcome(.failed))
        let childItem = try attempted.transition(to: .outcome(.written))
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: finishedAt,
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [parentItem],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        try context.insert(PersistedRunWorkItem(
            runID: record.runID.rawValue,
            itemID: childItem.id,
            position: 0,
            itemData: JSONEncoder().encode(childItem)
        ))
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>()).first)
        row.finishedAt = nil
        try context.save()
        let freshStore = RunRecordDataStore(modelContainer: container)

        let didClose = try await freshStore.closeCorruptedRun(record.runID, at: startedAt)
        let page = try await freshStore.reports(matching: RunReportQuery())
        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunWorkItem>())
        let childData = try #require(rows.first).itemData
        let storedChild = try JSONDecoder().decode(
            RunWorkItem.self,
            from: childData
        )

        #expect(didClose == false)
        #expect(page.attentionRunIDs == [record.runID])
        #expect(storedChild == childItem)
    }

    private func repairTransitions() -> [RunLifecycleTransition] {
        [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .recoverable, timestamp: Date(timeIntervalSince1970: 101))
        ]
    }
}

enum PayloadTruncation: CaseIterable, Sendable {
    case prefix
    case suffix
}
