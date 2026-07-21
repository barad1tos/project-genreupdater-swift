import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator write runs")
struct WriteTests {
    @Test("write run preserves its submitted input")
    func writeRunPreservesInput() async throws {
        let probe = WriteRecordProbe()
        let sync = WriteSyncProbe()
        let target = writeTarget()
        let input = writeInput(target: target, artists: ["Björk"], knownTrackCount: 12)
        let itemID = try #require(input.workItems.first?.id)
        let writtenItem = try input.workItems[0]
            .transition(to: .attempting)
            .transition(to: .attempted)
            .transition(to: .outcome(.written))
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await sync.run() },
            persistRunRecord: { try await probe.append($0) },
            write: .init(writeFixPlan: { submittedInput, checkpoint in
                try await checkpoint(.beforeAttempt([itemID]))
                try await checkpoint(.afterAttempt([itemID]))
                try await checkpoint(.afterVerification([itemID: .written]))
                return try await writer.apply(input: submittedInput)
            }),
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(await writer.calls == [input])
        #expect(await sync.callCount == 0)

        let final = try #require(await probe.records.last)
        #expect(final.intent == .writeFixes)
        #expect(final.scope == input.scope)
        #expect(final.writeTarget == input.target)
        #expect(final.configuration == input.configuration)
        #expect(final.workItems == [writtenItem])
        #expect(final.syncSummary?.modified == 1)
        #expect(final.writeSummary == RunWriteSummary(applied: 1, verifiedNoOp: 0, failed: 0))
        #expect(final.transitions.map(\.state) == [
            .created,
            .writing,
            .verifying,
            .reporting,
            .completed,
        ])
        #expect(await probe.records.compactMap { $0.workItems.first?.state } == [
            .prepared,
            .attempting,
            .attempted,
            .outcome(.written),
            .outcome(.written),
        ])
    }

    @Test("write run fails when reviewed writes partially fail")
    func writeFailsPartialFailure() async throws {
        let probe = WriteRecordProbe()
        let target = writeTarget()
        let input = writeInput(target: target, artists: ["Björk"], knownTrackCount: 12)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            noOpEntries: [writeEntry()],
            failedTrackIDs: ["track-2"],
            errorDescriptions: ["Failed to write genre for track track-2"]
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            write: .init(writeFixPlan: { input, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writer.apply(input: input)
            }),
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        #expect(await writer.calls == [input])

        let final = try #require(await probe.records.last)
        #expect(final.intent == .writeFixes)
        #expect(final.failureMessage?.contains("Write run partially failed") == true)
        #expect(final.failureMessage?.contains("Failed to write genre for track track-2") == true)
        #expect(final.syncSummary?.modified == 1)
        #expect(final.writeSummary == RunWriteSummary(applied: 1, verifiedNoOp: 1, failed: 1))
        #expect(final.transitions.map(\.state) == [
            .created,
            .writing,
            .verifying,
            .reporting,
            .failed,
        ])
    }

    @Test("write run without a writer fails before shared sync")
    func writeWithoutRunnerFails() async throws {
        let probe = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.failureMessage == "Fix plan write runner is unavailable")
        #expect(final.transitions.map(\.state) == [
            .created,
            .writing,
            .reporting,
            .failed,
        ])
    }

    @Test("different queued write targets run in FIFO order")
    func queuedWritesRunInOrder() async {
        let syncGate = WriteSyncGate()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await syncGate.sync() },
            persistRunRecord: { _ in },
            write: .init(writeFixPlan: { input, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writer.apply(input: input)
            }),
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let firstTarget = writeTarget()
        let secondTarget = writeTarget()
        let firstInput = writeInput(target: firstTarget)
        let secondInput = writeInput(target: secondTarget)

        let active = Task {
            await orchestrator.submit(RunRequest.observation(
                trigger: .backgroundSync,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncGate.waitUntilCount(1)

        let firstQueue = await orchestrator.submit(.manualWrite(input: firstInput))
        let secondQueue = await orchestrator.submit(.manualWrite(input: secondInput))

        guard case .queued = firstQueue, case .queued = secondQueue else {
            Issue.record("Expected both write targets to queue")
            return
        }

        await syncGate.release()
        _ = await active.value
        await writer.waitUntilCallCount(2)

        #expect(await writer.calls == [firstInput, secondInput])
        #expect(await syncGate.callCount == 1)
    }
}
