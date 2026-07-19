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
        AuditCondition.allCases
    )
    func rejectsMissingAudit(
        _ schema: AuditSchema,
        _ condition: AuditCondition
    ) async throws {
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
        switch condition.field {
        case .missing:
            object.removeValue(forKey: "workItems")
        case .null:
            object["workItems"] = NSNull()
        }
        switch condition.configuration {
        case .valid:
            break
        case .malformed:
            object["configuration"] = "malformed"
        case .null:
            object["configuration"] = NSNull()
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
        try await expectAttention(runID, in: store)
    }

    @Test("Recovery preserves explicit-null audits", arguments: UnknownItemSchema.allCases)
    func holdsNullAudit(_ schema: UnknownItemSchema) async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let payload = ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [],
            configuration: nil
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
        object["workItems"] = NSNull()
        object.removeValue(forKey: "configuration")
        let storedData = try JSONSerialization.data(withJSONObject: object)
        try insertRunRow(
            runID: runID,
            transitionsData: storedData,
            input: RunRowInput(intent: .writeFixes, state: .recoverable),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(didClose == false)
        #expect(rows.first?.transitionsData == storedData)
        try await expectAttention(runID, in: store)
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

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()) == false)
        try await expectAttention(runID, in: store)
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
        try await expectAttention(runID, in: store)
    }

    @Test("Header corruption cannot expose unsafe audit recovery", arguments: UnsafeRunHeader.allCases)
    func holdsUnsafeHeader(_ header: UnsafeRunHeader) async throws {
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
        var workItems = try #require(object["workItems"] as? [Any])
        workItems.append("malformed")
        object["workItems"] = workItems
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
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>()).first)
        switch header {
        case .intent:
            row.intentRaw = "invalid"
        case .state:
            row.stateRaw = "invalid"
        }
        try context.save()
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()) == false)
        try await expectAttention(runID, in: store)

        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(rows.first?.transitionsData == storedData)
    }

    @Test("Scope-detached item audit requires attention")
    func holdsDetachedScope() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let storedData = try JSONEncoder().encode(ItemPayload(
            version: RunRecordPayload.workItemVersion,
            transitions: recoveryTransitions(),
            workItems: [makeWorkItem(state: .attempted)],
            configuration: makeRunConfiguration(scopeID: UUID(), capturedAt: startedAt)
        ))
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

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()) == false)
        try await expectAttention(runID, in: store)

        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(rows.first?.transitionsData == storedData)
    }

    @Test("Prune preserves scope-detached item audit")
    func preservesDetachedAudit() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let unsafeRunID = UUID()
        let safeRunID = UUID()
        let unsafeStart = Date(timeIntervalSince1970: 100)
        let safeStart = Date(timeIntervalSince1970: 200)
        try insertTerminalAudit(
            runID: unsafeRunID,
            startedAt: unsafeStart,
            workItems: [makeWorkItem(state: .outcome(.skipped))],
            isDetached: true,
            into: container
        )
        try insertTerminalAudit(
            runID: safeRunID,
            startedAt: safeStart,
            workItems: [],
            isDetached: false,
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.prune(keepingLatest: 1) == 0)
        let page = try await store.reports(matching: RunReportQuery())
        #expect(page.attentionRunIDs == [RunID(rawValue: unsafeRunID)])
        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(Set(rows.map(\.runID)) == [unsafeRunID, safeRunID])
    }

    private func insertTerminalAudit(
        runID: UUID,
        startedAt: Date,
        workItems: [RunWorkItem],
        isDetached: Bool,
        into container: ModelContainer
    ) throws {
        let finishedAt = startedAt.addingTimeInterval(1)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let configurationScopeID = isDetached ? UUID() : scope.id
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .completedNoOp, timestamp: finishedAt)
                ],
                workItems: workItems,
                configuration: makeRunConfiguration(scopeID: configurationScopeID, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .observeLibrary,
                state: .completedNoOp,
                startedAt: startedAt,
                finishedAt: finishedAt
            ),
            into: container
        )
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
        try await expectAttention(runID, in: store)
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
        try await expectAttention(runID, in: store)
    }

    private func expectAttention(
        _ runID: UUID,
        in store: RunRecordDataStore
    ) async throws {
        let page = try await store.reports(matching: RunReportQuery())
        let expectedRunID = RunID(rawValue: runID)
        #expect(page.corruptedRunIDs == [expectedRunID])
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.attentionRunIDs == [expectedRunID])
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

struct AuditCondition: CaseIterable, Sendable {
    static let allCases = MissingItemField.allCases.flatMap { field in
        AuditConfiguration.allCases.map { configuration in
            Self(field: field, configuration: configuration)
        }
    }

    let field: MissingItemField
    let configuration: AuditConfiguration
}

enum AuditConfiguration: CaseIterable, Sendable {
    case valid
    case malformed
    case null
}

enum UnsafeRunHeader: CaseIterable, Sendable {
    case intent
    case state
}
