import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Work item audit safety", .serialized)
struct WorkAuditTests {
    @Test("Durable attempts cannot be regressed or removed")
    func rejectsAttemptLoss() async throws {
        let store = try makeRunStore()
        let item = makeWorkItem(state: .prepared)
        let startedAt = Date(timeIntervalSince1970: 100)
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)
        try await store.checkpoint(.beforeAttempt([item.id]), runID: record.runID)
        try await store.checkpoint(.afterAttempt([item.id]), runID: record.runID)

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(record)
        }
        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(terminalCopy(of: record, workItems: []))
        }

        #expect(try await store.record(for: record.runID)?.workItems.first?.state == .attempted)
    }

    @Test(
        "Checkpoints require active writing state",
        arguments: [RunLifecycleState.planningFixes, .blocked, .recoverable]
    )
    func requiresWritingState(_ state: RunLifecycleState) async throws {
        let store = try makeRunStore()
        let item = makeWorkItem(state: .prepared)
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: state,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        await #expect(throws: WorkCheckpointError.self) {
            try await store.checkpoint(.beforeAttempt([item.id]), runID: record.runID)
        }

        #expect(try await store.record(for: record.runID)?.workItems.first?.state == .prepared)
    }

    @Test("Checkpoints require reviewed-plan authority")
    func requiresReviewedAuthority() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let item = makeWorkItem(state: .prepared)
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                scope: scope,
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .readOnly
                ),
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        await #expect(throws: WorkCheckpointError.self) {
            try await store.checkpoint(.beforeAttempt([item.id]), runID: record.runID)
        }

        #expect(try await store.record(for: record.runID)?.workItems.first?.state == .prepared)
    }

    @Test(
        "Write-adjacent audit states require reviewed write authority",
        arguments: [WorkState.attempting, .attempted, .outcome(.written)]
    )
    func rejectsUnauthorizedWriteState(_ state: WorkState) async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let readOnlyConfiguration = makeRunConfiguration(
            scopeID: scope.id,
            capturedAt: startedAt,
            writeAuthority: .readOnly
        )
        let readOnlyWrite = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [makeWorkItem(state: state)],
                scope: scope,
                configuration: readOnlyConfiguration,
                includesSyncTransition: false
            )
        )
        let nonWriteRun = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .planningFixes,
            syncSummary: nil,
            input: RunRecordInput(
                workItems: [makeWorkItem(state: state)],
                includesSyncTransition: false
            )
        )

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(readOnlyWrite)
        }
        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(nonWriteRun)
        }
    }

    @Test("Open-to-terminal finalization cannot introduce an unauthorized write attempt")
    func rejectsUnauthorizedFinalization() async throws {
        let store = try makeRunStore()
        let item = makeWorkItem(state: .prepared)
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .planningFixes,
            syncSummary: nil,
            input: RunRecordInput(workItems: [item], includesSyncTransition: false)
        )
        try await store.upsert(record)

        await #expect(throws: RunRecordPersistenceError.self) {
            let attempting = try item.transition(to: .attempting)
            try await store.upsert(terminalCopy(of: record, workItems: [attempting]))
        }

        #expect(try await store.record(for: record.runID)?.workItems.first?.state == .prepared)
    }

    @Test("Decoded child audits cannot bypass write authority")
    func rejectsUnauthorizedChildAudit() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let configuration = makeRunConfiguration(
            scopeID: scope.id,
            capturedAt: startedAt,
            writeAuthority: .readOnly
        )
        let item = makeWorkItem(state: .prepared)
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                scope: scope,
                configuration: configuration,
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunWorkItem>()).first)
        row.itemData = try JSONEncoder().encode(
            item.transition(to: .attempting).transition(to: .attempted)
        )
        try context.save()

        let freshStore = RunRecordDataStore(modelContainer: container)
        await #expect(throws: RunRecordPersistenceError.self) {
            try await freshStore.record(for: record.runID)
        }
    }

    @Test("Decoded child audits preserve planned work identity")
    func rejectsChangedChildWork() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = makeWorkItem(state: .prepared)
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunWorkItem>()).first)
        row.itemData = try JSONEncoder().encode(RunWorkItem(
            id: item.id,
            target: item.target,
            change: WorkChange(
                changeType: item.change.changeType,
                oldValue: item.change.oldValue,
                newValue: "forged-value",
                confidence: item.change.confidence,
                source: item.change.source
            )
        ))
        try context.save()

        let freshStore = RunRecordDataStore(modelContainer: container)
        await #expect(throws: RunRecordPersistenceError.self) {
            try await freshStore.record(for: record.runID)
        }
    }

    @Test(
        "Decoded child audits cannot regress durable progress",
        arguments: [WorkState.attempted, .outcome(.written)]
    )
    func rejectsStateRegression(_ durableState: WorkState) async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = makeWorkItem(state: durableState)
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [item],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunWorkItem>()).first)
        row.itemData = try JSONEncoder().encode(RunWorkItem(
            id: item.id,
            target: item.target,
            change: item.change,
            state: .prepared,
            detail: item.detail
        ))
        try context.save()

        let freshStore = RunRecordDataStore(modelContainer: container)
        await #expect(throws: RunRecordPersistenceError.self) {
            try await freshStore.record(for: record.runID)
        }

        let recovery = try await freshStore.recoveryRecords()
        #expect(recovery.records.isEmpty)
        #expect(recovery.recoveryRunIDs.isEmpty)
        #expect(recovery.attentionRunIDs == [record.runID])
    }

    @Test("Malformed child audits degrade per run")
    func isolatesMalformedItem() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [makeWorkItem(state: .prepared)],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)
        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunWorkItem>()).first)
        row.itemData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try context.save()
        let freshStore = RunRecordDataStore(modelContainer: container)

        let reports = try await freshStore.reports(matching: RunReportQuery())
        let recovery = try await freshStore.recoveryRecords()

        #expect(reports.records.isEmpty)
        #expect(reports.skippedCorruptedCount == 1)
        #expect(reports.corruptedRunIDs == [record.runID])
        #expect(recovery.records.isEmpty)
        #expect(recovery.recoveryRunIDs.isEmpty)
        #expect(recovery.attentionRunIDs == [record.runID])
    }
}

private func terminalCopy(of record: RunRecord, workItems: [RunWorkItem]) -> RunRecord {
    let finishedAt = record.startedAt.addingTimeInterval(10)
    return RunRecord(
        header: RunRecord.Header(
            runID: record.runID,
            requestID: record.requestID,
            trigger: record.trigger,
            intent: record.intent,
            scope: record.scope,
            startedAt: record.startedAt
        ),
        configuration: record.configuration,
        writeTarget: record.writeTarget,
        recoveryID: record.recoveryID,
        transitions: record.transitions + [
            RunLifecycleTransition(state: .cancelled, timestamp: finishedAt)
        ],
        workItems: workItems,
        status: RunRecord.Status(
            syncSummary: record.syncSummary,
            writeSummary: record.writeSummary,
            failureMessage: "Cancelled",
            finishedAt: finishedAt
        )
    )
}
