import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator terminal persistence")
struct WriteTerminalStoreTests {
    @Test("write fails when its terminal record cannot persist")
    func failsUnstoredTerminal() async throws {
        let records = FailingRecordProbe(failingCall: 5)
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, _, checkpoint in
                    try await checkpointWrite(input, using: checkpoint)
                    return try await writer.apply(input: input)
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(reason.contains("Run history could not be finalized"))
        #expect(!reason.contains("Verify Music.app"))
        #expect(snapshot.state == .recoverable)
        #expect(await writer.calls.count == 1)
        let open = try #require(await records.records.first)
        #expect(open.state == .writing)
        #expect(open.finishedAt == nil)
        let recovered = try #require(await records.records.last)
        #expect(recovered.state == .recoverable)
        #expect(recovered.recoveryID == recoveryID)
        #expect(recovered.writeSummary?.applied == 1)
    }

    @Test("verified no-op does not publish completion when terminal persistence fails")
    func noOpFinalizationFailure() async throws {
        let records = FailingRecordProbe(failingCall: 3)
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, _, checkpoint in
                    try await checkpoint(.afterVerification([itemID: .noFixNeeded]))
                    return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
                },
                beginRecoveryHold: {
                    Issue.record("Verified no-op must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.state == .failed)
        #expect(snapshot.workItems.first?.state == .outcome(.noFixNeeded))
        let failedRecord = try #require(await records.records.last)
        #expect(failedRecord.transitions.filter { $0.state == .reporting }.count == 1)
        #expect(failedRecord.state == .failed)
        #expect(failedRecord.finishedAt != nil)
        #expect(await orchestrator.currentLifecycle()?.state == .failed)
    }

    @Test("verified no-op retains recovery when every terminal persistence attempt fails")
    func noOpRepeatedStoreFailure() async throws {
        let records = RejectingTerminalProbe()
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, _, checkpoint in
                    try await checkpoint(.afterVerification([itemID: .noFixNeeded]))
                    return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result after repeated terminal persistence failure")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(snapshot.workItems.first?.state == .outcome(.noFixNeeded))
        #expect(reason.contains("history could not be finalized"))
        #expect(!reason.contains("Verify Music.app"))
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }

    @Test("unstored failed terminal retains write authority")
    func failedTerminalStoreFailure() async throws {
        let records = FailedRunProbe()
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [],
            failedTrackIDs: ["track-1"],
            errorDescriptions: ["Write was rejected before dispatch"]
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { submittedInput, _, checkpoint in
                    try await checkpoint(.afterVerification([itemID: .failed]))
                    return try await writer.apply(input: submittedInput)
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(snapshot.workItems.first?.state == .outcome(.failed))
        #expect(reason.contains("Run history could not be finalized"))
        #expect(!reason.contains("Verify Music.app"))
        #expect(await records.failedAttempts == 2)
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)

        guard case let .recoverable(repeated, _) = await orchestrator.submit(.manualWrite(input: input)) else {
            Issue.record("Expected recovery hold to block another write")
            return
        }
        #expect(repeated.runID == snapshot.runID)
        #expect(await writer.calls.count == 1)
    }

    @Test("conclusive failed terminal retries persistence before recovery")
    func failedTerminalRetrySucceeds() async throws {
        let records = FailingRecordProbe(failingCall: 3)
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [],
            failedTrackIDs: ["track-1"],
            errorDescriptions: ["Write was rejected before dispatch"]
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { submittedInput, _, checkpoint in
                    try await checkpoint(.afterVerification([itemID: .failed]))
                    return try await writer.apply(input: submittedInput)
                },
                beginRecoveryHold: {
                    Issue.record("A successful failed-terminal retry must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result after a successful terminal retry")
            return
        }
        #expect(snapshot.state == .failed)
        #expect(snapshot.workItems.first?.state == .outcome(.failed))
        #expect(await records.records.last?.state == .failed)
        #expect(await writer.calls.count == 1)
    }

    @Test("partial write requires recovery when its terminal record cannot persist")
    func partialWriteStoreFailure() async {
        let records = FailingRecordProbe(failingCall: 5)
        let processing = ProcessingSuccessProbe()
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            noOpEntries: [],
            failedTrackIDs: ["track-2"],
            errorDescriptions: ["Failed to write genre for track track-2"]
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, _, checkpoint in
                    try await checkpointWrite(input, using: checkpoint)
                    return try await writer.apply(input: input)
                },
                beginRecoveryHold: { recoveryID }
            ),
            recordSuccessfulProcessing: { await processing.record() }
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(reason.contains("Run history could not be finalized"))
        #expect(reason.contains("Failed to write genre for track track-2"))
        #expect(!reason.contains("Verify Music.app"))
        #expect(await writer.calls.count == 1)
        #expect(await processing.callCount == 0)
        let recovered = await records.records.last
        #expect(recovered?.recoveryID == recoveryID)
        #expect(recovered?.writeSummary?.applied == 1)
        #expect(recovered?.writeSummary?.failed == 1)
        #expect(recovered?.failureMessage?.contains("Failed to write genre for track track-2") == true)
    }
}

private actor FailedRunProbe {
    private(set) var records: [RunRecord] = []
    private(set) var failedAttempts = 0

    func append(_ record: RunRecord) throws {
        if record.state == .failed, record.finishedAt != nil {
            failedAttempts += 1
            throw RecordWriteError()
        }
        records.append(record)
    }
}
