import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Work item recovery", .serialized)
struct WorkItemRecoveryTests {
    @Test("Recovery closes unknown schemas without work items", arguments: UnknownItemSchema.allCases)
    func closesEmptyUnknownSchema(_ schema: UnknownItemSchema) async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any])
        switch schema {
        case .malformed:
            object["version"] = "malformed"
        case .zero:
            object["version"] = 0
        }
        try insertRunRow(
            runID: runID,
            transitionsData: JSONSerialization.data(withJSONObject: object),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        #expect(didClose)
        #expect(try await store.record(for: RunID(rawValue: runID))?.workItems.isEmpty == true)
    }

    @Test(
        "Recovery preserves missing work-item audits",
        arguments: AuditSchema.allCases,
        MissingItemField.allCases
    )
    func rejectsMissingAudit(_ schema: AuditSchema, _ field: MissingItemField) async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any])
        switch schema {
        case .current:
            break
        case .malformed:
            object["version"] = "malformed"
        case .zero:
            object["version"] = 0
        }
        switch field {
        case .missing:
            object.removeValue(forKey: "workItems")
        case .null:
            object["workItems"] = NSNull()
        }
        let storedData = try JSONSerialization.data(withJSONObject: object)
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

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(didClose == false)
        #expect(rows.first?.transitionsData == storedData)
        #expect(try await store.reports(matching: RunReportQuery()).corruptedRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Recovery cannot detach work items from configuration")
    func rejectsConfigurationLoss() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let transitions = recoveryTransitions()
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: transitions,
                workItems: [makeWorkItem(state: .attempted)],
                configuration: nil
            )),
            input: RunRowInput(intent: .writeFixes, state: .recoverable),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())
        }
        #expect(try await store.reports(matching: RunReportQuery()).corruptedRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Recovery preserves valid items when one item is malformed")
    func rejectsPartialItemLoss() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [
                makeWorkItem(state: .outcome(.written)),
                makeWorkItem(state: .attempted)
            ],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any])
        var workItems = try #require(object["workItems"] as? [Any])
        workItems[1] = "malformed"
        object["workItems"] = workItems
        try insertRunRow(
            runID: runID,
            transitionsData: JSONSerialization.data(withJSONObject: object),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        #expect(didClose == false)
        #expect(try await store.reports(matching: RunReportQuery()).corruptedRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Recovery preserves work items when version is malformed")
    func rejectsMalformedItemVersion() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [makeWorkItem(state: .attempted)],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any])
        object["version"] = "malformed"
        try insertRunRow(
            runID: runID,
            transitionsData: JSONSerialization.data(withJSONObject: object),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        #expect(didClose == false)
        #expect(try await store.reports(matching: RunReportQuery()).corruptedRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Recovery preserves work items when version is below legacy")
    func rejectsVersionZero() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [makeWorkItem(state: .attempted)],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any])
        object["version"] = 0
        try insertRunRow(
            runID: runID,
            transitionsData: JSONSerialization.data(withJSONObject: object),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        #expect(didClose == false)
        #expect(try await store.reports(matching: RunReportQuery()).corruptedRunIDs == [RunID(rawValue: runID)])
    }

    private func recoveryTransitions() -> [RunLifecycleTransition] {
        [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .recoverable, timestamp: Date(timeIntervalSince1970: 101))
        ]
    }
}

enum UnknownItemSchema: CaseIterable, Sendable {
    case malformed
    case zero
}

enum MissingItemField: CaseIterable, Sendable {
    case missing
    case null
}

enum AuditSchema: CaseIterable, Sendable {
    case current
    case malformed
    case zero
}
