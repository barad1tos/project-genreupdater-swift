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
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
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
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
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
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
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
