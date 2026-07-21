import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator write cancellation")
struct WriteCancelTests {
    @Test("cancellation after a write attempt requires recovery")
    func cancellationAfterAttempt() async throws {
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
        #expect(snapshot.workItems.first?.state == .attempted)
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }

    @Test("cancellation before dispatch cancels the item without recovery")
    func cancelsBeforeDispatch() async throws {
        let records = WriteRecordProbe()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    throw CancellationError()
                },
                beginRecoveryHold: {
                    Issue.record("Pre-dispatch cancellation must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .cancelled(snapshot) = result else {
            Issue.record("Expected cancelled result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.skipped))
        #expect(await records.records.last?.state == .cancelled)
        #expect(await records.records.last?.recoveryID == nil)
        #expect(await records.records.last?.workItems.first?.state == .outcome(.skipped))
    }

    @Test("cancellation before any checkpoint fails when its terminal cannot persist")
    func failsUnstoredCancel() async throws {
        let records = FailingRecordProbe(failingCall: 2)
        let input = writeInput()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, _ in throw CancellationError() },
                beginRecoveryHold: {
                    Issue.record("A pre-attempt cancellation must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case .failed = result else {
            Issue.record("Expected failed result when the cancelled terminal cannot persist, got \(result)")
            return
        }
        let terminal = try #require(await records.records.last)
        #expect(terminal.state == .failed)
        #expect(terminal.finishedAt != nil)
        #expect(terminal.recoveryID == nil)
    }

    @Test("repeated terminal persistence failure keeps cancellation recoverable")
    func recoversRepeatedStoreFailure() async {
        let records = RejectingTerminalProbe()
        let recoveryID = UUID()
        let input = writeInput()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, _ in throw CancellationError() },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result after repeated terminal persistence failure")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(snapshot.finishedAt == nil)
        #expect(reason.contains("history could not be finalized"))
        #expect(!reason.contains("Verify Music.app"))
        #expect(await records.records.map(\.state) == [.writing, .recoverable])
        #expect(await records.records.last?.recoveryID == recoveryID)
        #expect(await records.records.allSatisfy { $0.finishedAt == nil })
    }

    @Test("cancellation closes untouched work items as skipped")
    func skipsRemainingOnCancel() async throws {
        let records = WriteRecordProbe()
        let first = makeWorkItem(state: .prepared)
        let second = makeWorkItem(state: .prepared)
        let input = writeInput(workItems: [first, second])
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([first.id]))
                    throw CancellationError()
                },
                beginRecoveryHold: {
                    Issue.record("Pre-dispatch cancellation must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .cancelled(snapshot) = result else {
            Issue.record("Expected cancelled result")
            return
        }
        #expect(snapshot.workItems.map(\.state) == [.outcome(.skipped), .outcome(.skipped)])
        let record = try #require(await records.records.last)
        #expect(record.state == .cancelled)
        #expect(record.workItems.map(\.state) == [.outcome(.skipped), .outcome(.skipped)])
    }

    @Test("pre-dispatch cancellation holds recovery when its terminal cannot persist")
    func holdsUnstoredCancellation() async throws {
        let records = FailingRecordProbe(failingCall: 3)
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    throw CancellationError()
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable result when the cancelled terminal cannot persist")
            return
        }
        #expect(snapshot.workItems.allSatisfy { $0.state == .outcome(.skipped) })
        #expect(!reason.contains("Verify Music.app"))
        #expect(await orchestrator.currentLifecycle()?.state == .recoverable)
        let retained = try #require(await records.records.last)
        #expect(retained.state == .recoverable)
        #expect(retained.workItems.allSatisfy { $0.state == .outcome(.skipped) })
        #expect(retained.finishedAt == nil)
        #expect(retained.recoveryID == recoveryID)
    }

    @Test("a fallback no-op after an undispatched attempt completes without recovery")
    func completesFallbackNoOp() async throws {
        let records = WriteRecordProbe()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    try await checkpoint(.afterVerification([itemID: .noFixNeeded]))
                    return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
                },
                beginRecoveryHold: {
                    Issue.record("A verified fallback no-op must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case .completedNoOp = result else {
            Issue.record("Expected a no-op completion, got \(result)")
            return
        }
        #expect(await records.records.last?.workItems.first?.state == .outcome(.noFixNeeded))
    }

    @Test("cancellation after a verified skip does not require recovery")
    func cancellationAfterSkip() async throws {
        let records = WriteRecordProbe()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.afterVerification([itemID: .skipped]))
                    throw CancellationError()
                },
                beginRecoveryHold: {
                    Issue.record("Verified skip must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .cancelled(snapshot) = result else {
            Issue.record("Expected cancelled result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.skipped))
        #expect(await records.records.last?.state == .cancelled)
        #expect(await records.records.last?.recoveryID == nil)
    }
}
