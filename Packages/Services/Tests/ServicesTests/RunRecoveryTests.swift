import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run record recovery persistence")
struct RunRecoveryTests {
    @Test("Recovery transitions clamp stale timestamps")
    func clampsRecoveryTimestamps() throws {
        let startedAt = Date(timeIntervalSince1970: 200)
        let workItems = [makeWorkItem(state: .attempted)]
        let record = makeRecoveryRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            input: RunRecordInput(intent: .writeFixes, workItems: workItems)
        )

        let opened = record.openingRecovery(id: UUID(), at: Date(timeIntervalSince1970: 100))
        let closed = opened.closingRecovery(at: Date(timeIntervalSince1970: 150))
        let previousTime = try #require(record.transitions.last?.timestamp)

        #expect(opened.transitions.last?.timestamp == previousTime)
        #expect(closed.transitions.suffix(2).map(\.timestamp) == [previousTime, previousTime])
        #expect(opened.workItems == workItems)
        #expect(closed.workItems == workItems)
        #expect(closed.finishedAt == previousTime)
    }

    @Test("Legacy run record JSON decodes without recovery fields")
    func decodesLegacyRecordJSON() throws {
        let record = makeRecoveryRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .recoverable,
            input: RunRecordInput(
                writeTarget: FixPlanWriteTarget(
                    planID: FixPlanID(),
                    planRevision: .initial,
                    decisionRevision: .initial
                ),
                recoveryID: UUID(),
                writeSummary: RunWriteSummary(applied: 1, verifiedNoOp: 0, failed: 0)
            )
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "writeTarget")
        object.removeValue(forKey: "recoveryID")
        object.removeValue(forKey: "writeSummary")
        object.removeValue(forKey: "configuration")
        object.removeValue(forKey: "workItems")

        let decoded = try JSONDecoder().decode(
            RunRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.writeTarget == nil)
        #expect(decoded.recoveryID == nil)
        #expect(decoded.writeSummary == nil)
        #expect(decoded.configuration == nil)
        #expect(decoded.transitions == record.transitions)
        #expect(decoded.workItems.isEmpty)
    }

    @Test("Run record JSON rejects a null work-item audit")
    func rejectsNullAudit() throws {
        let record = makeRecoveryRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .recoverable
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["workItems"] = NSNull()

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RunRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("Legacy store row decodes through payload fallback")
    func loadsLegacyRow() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .writing, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(transitions),
            input: RunRowInput(intent: .writeFixes, state: .writing),
            into: container
        )

        let record = try #require(await RunRecordDataStore(modelContainer: container).loadAll().first)

        #expect(record.runID == RunID(rawValue: runID))
        #expect(record.transitions == transitions)
        #expect(record.writeTarget == nil)
        #expect(record.recoveryID == nil)
        #expect(record.writeSummary == nil)
    }

    @Test("Opaque recovery data requires attention")
    func holdsOpaqueRecovery() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: corruptedData,
            input: RunRowInput(
                rawIntent: RunIntent.writeFixes.rawValue,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let recoveryPage = try await store.reports(matching: RunReportQuery(states: [.recoverable]))
        #expect(recoveryPage.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(recoveryPage.recoveryRunIDs.isEmpty)
        #expect(recoveryPage.attentionRunIDs == [RunID(rawValue: runID)])

        let didClose = try await store.closeCorruptedRun(
            RunID(rawValue: runID),
            at: Date(timeIntervalSince1970: 200)
        )

        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(didClose == false)
        #expect(rows.first?.transitionsData == corruptedData)
    }

    @Test("Blocked corrupted recovery cannot be dismissed")
    func keepsBlockedOpen() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: corruptedData,
            input: RunRowInput(
                rawIntent: RunIntent.writeFixes.rawValue,
                state: .blocked
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())
        let page = try await store.recoveryRecords()

        #expect(didClose == false)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Terminal corruption is reported without an actionable recovery ID")
    func excludesTerminalCorruption() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: corruptedData,
            input: RunRowInput(
                rawIntent: RunIntent.writeFixes.rawValue,
                state: .cancelled,
                finishedAt: Date(timeIntervalSince1970: 200)
            ),
            into: container
        )

        let page = try await RunRecordDataStore(modelContainer: container).reports(matching: RunReportQuery())

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
    }

    @Test("Unsupported payload version stays open")
    func preservesFuturePayload() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let payload = FuturePayload()
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(payload),
            input: RunRowInput(
                rawIntent: RunIntent.writeFixes.rawValue,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())
        let page = try await store.recoveryRecords()

        #expect(didClose == false)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.unsupportedRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Payload versions below legacy can use explicit corrupted closure")
    func closesInvalidVersion() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .recoverable, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(InvalidVersionPayload(version: 0, transitions: transitions)),
            input: RunRowInput(intent: .writeFixes, state: .recoverable),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        do {
            _ = try await store.loadAll()
            Issue.record("Expected version zero to be classified as malformed")
        } catch let RunRecordPersistenceError.malformedPayloadVersion(errorRunID) {
            #expect(errorRunID == runID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.state == .cancelled)
        #expect(audit.transitions.starts(with: transitions))
    }

    @Test("Unfinished reporting write can be claimed for recovery")
    func claimsReportingWrite() async throws {
        let store = try makeRunStore()
        let record = makeRecoveryRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .reporting,
            input: RunRecordInput(intent: .writeFixes)
        )
        try await store.upsert(record)
        let recoveryID = UUID()

        let claimedID = try await store.claimRecovery(for: record.runID, id: recoveryID, at: Date())
        let claimed = try #require(await store.record(for: record.runID))

        #expect(claimedID == recoveryID)
        #expect(claimed.state == .recoverable)
        #expect(claimed.recoveryID == recoveryID)
    }

    @Test("Attempted checkpoint keeps its writing parent recoverable")
    func restoresAttemptedCheckpoint() async throws {
        let store = try makeRunStore()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let record = makeRecoveryRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .writing,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: input.target,
                workItems: input.workItems
            )
        )
        try await store.upsert(record)
        try await store.checkpoint(.beforeAttempt([itemID]), runID: record.runID)
        try await store.checkpoint(.afterAttempt([itemID]), runID: record.runID)

        let interrupted = try #require(await store.recoveryRecords().records.first)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in
                // The test restores the record already persisted above.
            }
        ))
        await orchestrator.restoreRecovery(interrupted)
        let recoveryID = UUID()

        #expect(interrupted.state == .writing)
        #expect(interrupted.workItems.first?.state == .attempted)
        #expect(await orchestrator.currentLifecycle()?.state == .recoverable)
        #expect(try await store.claimRecovery(for: record.runID, id: recoveryID, at: Date()) == recoveryID)
    }

    @Test("Recovery discovery fails closed for an invalid intent")
    func invalidIntentHolds() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: corruptedData,
            input: RunRowInput(rawIntent: "invalid", state: .writing),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Read-only runs are not recovery candidates")
    func excludesReadOnlyRuns() async throws {
        let store = try makeRunStore()
        let record = makeRecoveryRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .reporting,
            input: RunRecordInput(intent: .observeLibrary)
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

    @Test("Opaque read-only rows require attention")
    func holdsOpaqueReadOnly() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: corruptedData,
            input: RunRowInput(
                rawIntent: RunIntent.observeLibrary.rawValue,
                state: .reporting
            ),
            into: container
        )

        let store = RunRecordDataStore(modelContainer: container)
        let page = try await store.recoveryRecords()
        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.closableRunIDs.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Blocked read-only corruption requires an explicit decision")
    func flagsBlockedRun() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: corruptedData,
            input: RunRowInput(intent: .observeLibrary, state: .blocked),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.closableRunIDs.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Future read-only payloads fail closed without automatic closure")
    func holdsFuturePayload() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(FuturePayload()),
            input: RunRowInput(intent: .observeLibrary, state: .reporting),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.closableRunIDs.isEmpty)
        #expect(page.attentionRunIDs.isEmpty)
        #expect(page.unsupportedRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
        #expect(try await store.recoveryRecords().unsupportedRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Healthy open writes cannot use corrupted recovery closure")
    func rejectsHealthyClosure() async throws {
        let store = try makeRunStore()
        let record = makeRecoveryRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .reporting,
            input: RunRecordInput(intent: .writeFixes)
        )
        try await store.upsert(record)

        let didClose = try await store.closeCorruptedRun(record.runID, at: Date())

        #expect(didClose == false)
        #expect(try await store.record(for: record.runID) == record)
    }

    @Test("claimRecovery keeps the first ID and rejects terminal records")
    func keepsRecoveryID() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let open = makeRecoveryRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            input: RunRecordInput(intent: .writeFixes)
        )
        let terminal = makeRecoveryRecord(
            startedAt: startedAt,
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completed,
            input: RunRecordInput(intent: .writeFixes)
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
}

private struct FuturePayload: Encodable {
    let version = 4
    let futureState = "incompatible-v4"
}
