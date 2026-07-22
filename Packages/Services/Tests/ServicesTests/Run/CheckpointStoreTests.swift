import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator checkpoint storage")
struct CheckpointStoreTests {
    @Test("pre-attempt checkpoint failure prevents write dispatch")
    func preAttemptStoreFailure() async throws {
        let records = FailingRecordProbe(failingCall: 2)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(writeFixPlan: { submittedInput, checkpoint in
                try await checkpoint(.beforeAttempt([itemID]))
                return try await writer.apply(input: submittedInput)
            })
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.failed))
        #expect(snapshot.finishedAt != nil)
        #expect(await writer.calls.isEmpty)
        #expect(await records.records.last?.workItems.first?.state == .outcome(.failed))
    }

    @Test("post-attempt checkpoint failure requires recovery")
    func postAttemptStoreFailure() async throws {
        let records = FailingRecordProbe(failingCall: 3)
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { submittedInput, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    let result = try await writer.apply(input: submittedInput)
                    try await checkpoint(.afterAttempt([itemID]))
                    return result
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
        #expect(snapshot.workItems.first?.state == .attempted)
        #expect(reason.contains("Verify Music.app"))
        #expect(!reason.contains("Write finished"))
        #expect(await writer.calls.count == 1)
        #expect(await records.records.last?.recoveryID == recoveryID)
        #expect(await records.records.last?.workItems.first?.state == .attempted)
    }

    @Test("a rejected writer closes every unstarted work item")
    func closesUnstartedWork() async {
        let records = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(writeFixPlan: { _, _ in throw RecordWriteError() })
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.finishedAt != nil)
        #expect(snapshot.workItems.allSatisfy { $0.state == .outcome(.failed) })
        #expect(await records.records.last?.workItems.allSatisfy {
            $0.state == .outcome(.failed)
        } == true)
    }

    @Test("a duplicate work ledger fails closed without dispatch")
    func holdsDuplicateLedger() async {
        let item = makeWorkItem(state: .prepared)
        let input = writeInput(workItems: [item, item])
        let records = WriteRecordProbe()
        let attempts = CheckpointCallProbe()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let recoveryID = UUID()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { submittedInput, checkpoint in
                    await attempts.record()
                    try await checkpoint(.beforeAttempt(submittedInput.workItems.map(\.id)))
                    return try await writer.apply(input: submittedInput)
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable history hold")
            return
        }
        #expect(snapshot.workItems == [item, item])
        #expect(await attempts.count == 1)
        #expect(await writer.calls.isEmpty)
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }

    @Test("a failed verification checkpoint retains its terminal candidate")
    func retainsFailedCandidate() async throws {
        let records = FailingRecordProbe(failingCall: 3)
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    try await checkpoint(.afterVerification([itemID: .failed]))
                    return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
                },
                beginRecoveryHold: {
                    Issue.record("A conclusive failed candidate must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.failed))
        #expect(await records.records.last?.workItems.first?.state == .outcome(.failed))
    }

    @Test("a written verification checkpoint retains its terminal candidate")
    func retainsWrittenCandidate() async throws {
        let records = FailingRecordProbe(failingCall: 4)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { submittedInput, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    let result = try await writer.apply(input: submittedInput)
                    try await checkpoint(.afterAttempt([itemID]))
                    try await checkpoint(.afterVerification([itemID: .written]))
                    return result
                },
                beginRecoveryHold: {
                    Issue.record("A verified written candidate must not open recovery")
                    return UUID()
                }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.written))
        #expect(await writer.calls.count == 1)
        #expect(await records.records.last?.workItems.first?.state == .outcome(.written))
    }

    @Test("an unstored checkpoint candidate is hidden until terminal persistence")
    func hidesUnstoredCandidate() async throws {
        let records = FailingRecordProbe(failingCall: 4)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(writeFixPlan: { submittedInput, checkpoint in
                try await checkpoint(.beforeAttempt([itemID]))
                let result = try await writer.apply(input: submittedInput)
                try await checkpoint(.afterAttempt([itemID]))
                try await checkpoint(.afterVerification([itemID: .written]))
                return result
            })
        ))
        let updates = await orchestrator.lifecycleUpdates()
        let collector = Task { () -> [RunLifecycleSnapshot] in
            var snapshots: [RunLifecycleSnapshot] = []
            for await snapshot in updates {
                snapshots.append(snapshot)
                if !snapshot.isActive {
                    break
                }
            }
            return snapshots
        }

        let result = await orchestrator.submit(.manualWrite(input: input))
        let snapshots = await collector.value

        guard case let .failed(terminal) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshots.last == terminal)
        #expect(snapshots.dropLast().allSatisfy {
            $0.workItems.first?.state != .outcome(.written)
        })
        #expect(!snapshots.contains {
            $0.state == .reporting && $0.workItems.first?.state == .outcome(.written)
        })
    }

    @Test("conclusive work remains recoverable when terminal persistence is unavailable")
    func holdsConclusiveFailure() async throws {
        let records = FailingRecordProbe(failingCalls: [3, 4, 5])
        let recoveryID = UUID()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.beforeAttempt([itemID]))
                    try await checkpoint(.afterVerification([itemID: .failed]))
                    return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable history hold")
            return
        }
        #expect(snapshot.workItems.first?.state == .outcome(.failed))
        #expect(!snapshot.hasOpenItems)
        #expect(!reason.contains("Verify Music.app"))
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
    }

    @Test("an unstored recovery falls back to the last durable checkpoint")
    func usesDurableFallback() async throws {
        let records = FailingRecordProbe(failingCalls: [4, 5, 6])
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(writeFixPlan: { submittedInput, checkpoint in
                try await checkpoint(.beforeAttempt([itemID]))
                let result = try await writer.apply(input: submittedInput)
                try await checkpoint(.afterAttempt([itemID]))
                try await checkpoint(.afterVerification([itemID: .written]))
                return result
            })
        ))
        let updates = await orchestrator.lifecycleUpdates()
        let collector = Task { () -> [RunLifecycleSnapshot] in
            var snapshots: [RunLifecycleSnapshot] = []
            for await snapshot in updates {
                snapshots.append(snapshot)
                if !snapshot.isActive {
                    break
                }
            }
            return snapshots
        }

        let result = await orchestrator.submit(.manualWrite(input: input))
        let snapshots = await collector.value

        guard case let .recoverable(snapshot, reason) = result else {
            Issue.record("Expected recoverable history hold")
            return
        }
        #expect(snapshot.workItems.first?.state == .attempted)
        #expect(reason.contains("Verify Music.app"))
        #expect(!snapshots.contains {
            $0.workItems.first?.state == .outcome(.written)
        })
        #expect(await orchestrator.currentLifecycle()?.workItems.first?.state == .attempted)
        #expect(await records.records.last?.workItems.first?.state == .attempted)
        #expect(await writer.calls.count == 1)
    }
}

private actor CheckpointCallProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
