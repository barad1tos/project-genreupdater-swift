import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run record recovery persistence")
struct RunRecoveryTests {
    @Test("Legacy run record JSON decodes without recovery fields")
    func decodesLegacyRecordJSON() throws {
        let record = makeRecord(
            writeTarget: FixPlanWriteTarget(
                planID: FixPlanID(),
                planRevision: .initial,
                decisionRevision: .initial
            ),
            recoveryID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .recoverable,
            writeSummary: RunWriteSummary(applied: 1, verifiedNoOp: 0, failed: 0)
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "writeTarget")
        object.removeValue(forKey: "recoveryID")
        object.removeValue(forKey: "writeSummary")

        let decoded = try JSONDecoder().decode(
            RunRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.writeTarget == nil)
        #expect(decoded.recoveryID == nil)
        #expect(decoded.writeSummary == nil)
        #expect(decoded.transitions == record.transitions)
    }

    @Test("Legacy store row decodes through payload fallback")
    func loadsLegacyRow() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .writing, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(transitions),
            state: .writing,
            into: container
        )

        let record = try #require(await RunRecordDataStore(modelContainer: container).loadAll().first)

        #expect(record.runID == RunID(rawValue: runID))
        #expect(record.transitions == transitions)
        #expect(record.writeTarget == nil)
        #expect(record.recoveryID == nil)
        #expect(record.writeSummary == nil)
    }

    @Test("Corrupted recovery closure creates a readable terminal audit record")
    func closesCorruptedRecovery() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRow(
            runID: runID,
            transitionsData: corruptedData,
            intentRaw: RunIntent.writeFixes.rawValue,
            state: .recoverable,
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let recoveryPage = try await store.reports(matching: RunReportQuery(states: [.recoverable]))
        #expect(recoveryPage.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(recoveryPage.recoveryRunIDs == [RunID(rawValue: runID)])

        let didClose = try await store.closeCorruptedRun(
            RunID(rawValue: runID),
            at: Date(timeIntervalSince1970: 200)
        )

        let closedPage = try await store.reports(matching: RunReportQuery(states: [.recoverable]))
        let auditPage = try await store.reports(matching: RunReportQuery())
        #expect(closedPage.skippedCorruptedCount == 0)
        #expect(didClose)
        #expect(auditPage.skippedCorruptedCount == 0)
        #expect(auditPage.corruptedRunIDs.isEmpty)
        #expect(auditPage.recoveryRunIDs.isEmpty)
        let audit = try #require(auditPage.records.first)
        #expect(audit.runID == RunID(rawValue: runID))
        #expect(audit.state == .cancelled)
        #expect(audit.finishedAt == Date(timeIntervalSince1970: 200))
        #expect(audit.failureMessage?.contains("stored run payload was corrupted") == true)
    }

    @Test("Blocked corrupted recovery cannot be dismissed")
    func blockedCorruptionStaysOpen() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRow(
            runID: runID,
            transitionsData: corruptedData,
            intentRaw: RunIntent.writeFixes.rawValue,
            state: .blocked,
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())
        let page = try await store.recoveryRecords()

        #expect(didClose == false)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Terminal corruption is reported without an actionable recovery ID")
    func terminalCorruptionIsNotActionable() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRow(
            runID: runID,
            transitionsData: corruptedData,
            intentRaw: RunIntent.writeFixes.rawValue,
            state: .cancelled,
            finishedAt: Date(timeIntervalSince1970: 200),
            into: container
        )

        let page = try await RunRecordDataStore(modelContainer: container).reports(matching: RunReportQuery())

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
    }

    @Test("Unsupported payload version stays open")
    func unsupportedPayloadStaysOpen() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let payload = FuturePayload()
        try insertRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(payload),
            intentRaw: RunIntent.writeFixes.rawValue,
            state: .recoverable,
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())
        let page = try await store.recoveryRecords()

        #expect(didClose == false)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Unfinished reporting write can be claimed for recovery")
    func reportingWriteCanBeClaimed() async throws {
        let store = try makeStore()
        let record = makeRecord(
            intent: .writeFixes,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .reporting
        )
        try await store.upsert(record)
        let recoveryID = UUID()

        let claimedID = try await store.claimRecovery(for: record.runID, id: recoveryID, at: Date())
        let claimed = try #require(await store.record(for: record.runID))

        #expect(claimedID == recoveryID)
        #expect(claimed.state == .recoverable)
        #expect(claimed.recoveryID == recoveryID)
    }

    @Test("Recovery discovery fails closed for an invalid intent")
    func invalidIntentHolds() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRow(
            runID: runID,
            transitionsData: corruptedData,
            intentRaw: "invalid",
            state: .writing,
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
    }

    @Test("Read-only runs are not recovery candidates")
    func readOnlyRunsAreNotRecoverable() async throws {
        let store = try makeStore()
        let record = makeRecord(
            intent: .observeLibrary,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .reporting
        )
        try await store.upsert(record)

        let page = try await store.recoveryRecords()
        let claim = try await store.claimRecovery(for: record.runID, id: UUID(), at: Date())
        let didClose = try await store.closeCorruptedRun(record.runID, at: Date())

        #expect(page.records.isEmpty)
        #expect(page.corruptedRunIDs.isEmpty)
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(claim == nil)
        #expect(didClose == false)
        #expect(try await store.record(for: record.runID) == record)
    }

    @Test("Corrupted read-only rows are reported but not actionable")
    func corruptedReadOnlyRunIsNotActionable() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRow(
            runID: runID,
            transitionsData: corruptedData,
            intentRaw: RunIntent.observeLibrary.rawValue,
            state: .reporting,
            into: container
        )

        let page = try await RunRecordDataStore(modelContainer: container).reports(matching: RunReportQuery())

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
    }

    @Test("Healthy open writes cannot use corrupted recovery closure")
    func healthyWriteCannotCloseAsCorrupted() async throws {
        let store = try makeStore()
        let record = makeRecord(
            intent: .writeFixes,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .reporting
        )
        try await store.upsert(record)

        let didClose = try await store.closeCorruptedRun(record.runID, at: Date())

        #expect(didClose == false)
        #expect(try await store.record(for: record.runID) == record)
    }

    @Test("claimRecovery keeps the first ID and rejects terminal records")
    func claimRecoveryKeepsFirstID() async throws {
        let store = try makeStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let open = makeRecord(
            intent: .writeFixes,
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing
        )
        let terminal = makeRecord(
            intent: .writeFixes,
            startedAt: startedAt,
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completed
        )
        try await store.upsert(open)
        try await store.upsert(terminal)
        let recoveryID = UUID()

        let claimedID = try await store.claimRecovery(
            for: open.runID,
            id: recoveryID,
            at: Date(timeIntervalSince1970: 105)
        )
        let secondID = UUID()
        let repeatedID = try await store.claimRecovery(
            for: open.runID,
            id: secondID,
            at: Date(timeIntervalSince1970: 106)
        )
        let rejectedID = try await store.claimRecovery(
            for: terminal.runID,
            id: recoveryID,
            at: Date(timeIntervalSince1970: 105)
        )

        #expect(claimedID == recoveryID)
        #expect(repeatedID == recoveryID)
        #expect(try await store.record(for: open.runID)?.state == .recoverable)
        #expect(try await store.record(for: open.runID)?.recoveryID == recoveryID)
        #expect(rejectedID == nil)
        #expect(try await store.record(for: terminal.runID) == terminal)
    }

    private var corruptedData: Data {
        Data([0xDE, 0xAD, 0xBE, 0xEF])
    }

    private func insertRow(
        runID: UUID,
        transitionsData: Data,
        intentRaw: String = RunIntent.observeLibrary.rawValue,
        state: RunLifecycleState,
        finishedAt: Date? = nil,
        into container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "manualCheck"
        )
        try context.insert(PersistedRunRecord(
            runID: runID,
            requestID: UUID(),
            triggerRaw: RunTrigger.manualCheck.rawValue,
            intentRaw: intentRaw,
            stateRaw: state.rawValue,
            scopeData: JSONEncoder().encode(scope),
            transitionsData: transitionsData,
            syncNewCount: nil,
            syncModifiedCount: nil,
            syncIdentityChangedCount: nil,
            syncRefreshedCount: nil,
            syncRemovedCount: nil,
            failureMessage: nil,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: finishedAt
        ))
        try context.save()
    }

    private func makeStore() throws -> RunRecordDataStore {
        try RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())
    }

    private func makeRecord(
        intent: RunIntent = .observeLibrary,
        writeTarget: FixPlanWriteTarget? = nil,
        recoveryID: UUID? = nil,
        startedAt: Date,
        finishedAt: Date?,
        state: RunLifecycleState,
        writeSummary: RunWriteSummary? = nil
    ) -> RunRecord {
        var transitions = [RunLifecycleTransition(state: .created, timestamp: startedAt)]
        if state != .created {
            transitions.append(RunLifecycleTransition(
                state: state,
                timestamp: finishedAt ?? startedAt.addingTimeInterval(1)
            ))
        }
        return RunRecord(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: intent,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Aphex Twin"],
                knownTrackCount: 75,
                createdAt: startedAt,
                reason: "manualCheck"
            ),
            writeTarget: writeTarget,
            recoveryID: recoveryID,
            transitions: transitions,
            syncSummary: nil,
            writeSummary: writeSummary,
            failureMessage: nil,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

private struct FuturePayload: Encodable {
    let version = 2
    let futureState = "incompatible-v2"
}
