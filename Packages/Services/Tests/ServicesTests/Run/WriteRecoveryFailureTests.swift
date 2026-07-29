import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator write recovery failures")
struct WriteRecoveryFailureTests {
    @Test("write retains authority when no run record can persist")
    func persistenceBlocksWrite() async {
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in throw RecordWriteError() },
            write: .init(
                writeFixPlan: { input, _ in try await writer.apply(input: input) },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(reason.contains("run history is unavailable"))
        #expect(!reason.contains("Verify Music.app"))

        guard case let .recoverable(repeated, _) = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected recovery hold to block another write")
            return
        }
        #expect(repeated.runID == snapshot.runID)
        #expect(await writer.calls.isEmpty)
    }

    @Test("finalization failure after an attempted write requires recovery")
    func finalizationFailureRecovers() async throws {
        let records = WriteRecordProbe()
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    try await checkpoint(.afterAttempt([itemID]))
                    throw UpdateCoordinatorError.writeFinalizationFailed(
                        trackID: "track-1",
                        effects: ["change log"]
                    )
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
        #expect(snapshot.finishedAt == nil)
        #expect(snapshot.workItems.first?.state == .attempted)
        #expect(reason.contains("Music.app updated track track-1"))
        let record = try #require(await records.records.last)
        #expect(record.state == .recoverable)
        #expect(record.finishedAt == nil)
        #expect(record.recoveryID == recoveryID)
    }

    @Test("an unexpected error after an attempted write requires recovery")
    func genericErrorRecovers() async throws {
        let records = WriteRecordProbe()
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    try await checkpoint(.afterAttempt([itemID]))
                    throw RecordWriteError()
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.workItems.first?.state == .attempted)
        let record = try #require(await records.records.last)
        #expect(record.state == .recoverable)
        #expect(record.finishedAt == nil)
        #expect(record.recoveryID == recoveryID)
    }

    @Test("a writer cannot complete with unfinished work items")
    func rejectsMissingCheckpoints() async {
        let records = WriteRecordProbe()
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, _ in try await writer.apply(input: input) },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .recoverable(_, reason) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(reason.contains("unfinished work items"))
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }

    @Test("recovery stays active when its state cannot persist")
    func unstoredRecoveryRemains() async throws {
        let records = FailingRecordProbe(failingCall: 4)
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    try await checkpoint(.afterAttempt([itemID]))
                    throw RecordWriteError()
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(await orchestrator.currentLifecycle()?.state == .recoverable)
        let checkpoint = try #require(await records.records.last)
        #expect(checkpoint.state == .writing)
        #expect(checkpoint.workItems.first?.state == .attempted)
        #expect(checkpoint.finishedAt == nil)
        guard case .recoverable = await orchestrator.submit(.manualWrite(input: input)) else {
            Issue.record("Expected unresolved recovery to keep writes gated")
            return
        }
    }

    @Test("written checkpoint holds recovery when failed finalization cannot persist")
    func unstoredWrittenOutcomeRecovers() async {
        let records = FailingRecordProbe(failingCall: 5)
        let recoveryID = UUID()
        let input = writeInput()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await checkpointWrite(input, using: checkpoint)
                    throw RecordWriteError()
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.written))
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }

    @Test("written checkpoint holds recovery when cancelled finalization cannot persist")
    func unstoredWrittenCancellationRecovers() async {
        let records = FailingRecordProbe(failingCall: 5)
        let recoveryID = UUID()
        let input = writeInput()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await checkpointWrite(input, using: checkpoint)
                    throw CancellationError()
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.written))
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }
}
