import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator write recovery")
struct WriteRecoveryTests {
    @Test("unknown write outcome opens recovery and drops queued writes")
    func unknownOutcomeSuspends() async throws {
        let probe = WriteRecordProbe()
        let writer = RecoveryWriteProbe()
        let recoveryID = UUID()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await writer.apply(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { recoveryID }
            ),
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let firstInput = writeInput()
        let secondInput = writeInput()
        let thirdInput = writeInput()
        let first = Task { await orchestrator.submit(.manualWrite(input: firstInput)) }
        await writer.waitUntilCalled()

        let queued = await orchestrator.submit(.manualWrite(input: secondInput))
        guard case .queued = queued else {
            Issue.record("Expected second write to queue")
            return
        }
        await writer.release()

        guard case let .recoverable(snapshot, reason) = await first.value else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(reason.contains("outcome is unknown"))
        let recoverable = try #require(await probe.records.last)
        #expect(recoverable.finishedAt == nil)
        #expect(recoverable.state == .recoverable)
        #expect(recoverable.recoveryID == recoveryID)
        #expect(recoverable.writeTarget == firstInput.target)
        #expect(recoverable.failureMessage?.contains("outcome is unknown") == true)
        #expect(recoverable.transitions.map(\.state) == [.created, .writing, .recoverable])

        guard case .recoverable = await orchestrator.submit(.manualWrite(input: thirdInput)) else {
            Issue.record("Expected a later write submission to remain recovery-gated")
            return
        }
        #expect(await writer.calls == [firstInput])

        await orchestrator.resolveRecovery(runID: snapshot.runID, at: Date(timeIntervalSince1970: 200))
        #expect(await orchestrator.currentLifecycle()?.state == .cancelled)
        guard case .completed = await orchestrator.submit(.manualWrite(input: thirdInput)) else {
            Issue.record("Expected write submission after recovery resolution to complete")
            return
        }
        #expect(await writer.calls == [firstInput, thirdInput])
    }

    @Test("unknown outcome preserves queued recovery reads")
    func recoveryReadSurvives() async {
        let writer = RecoveryWriteProbe()
        let syncGate = WriteSyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await syncGate.sync() },
            persistRunRecord: { _ in },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await writer.apply(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { UUID() }
            )
        ))
        let active = Task { await orchestrator.submit(.manualWrite(input: writeInput())) }
        await writer.waitUntilCalled()

        let queued = await orchestrator.submit(.observation(
            trigger: .recovery,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        guard case .queued = queued else {
            Issue.record("Expected recovery read to queue")
            return
        }
        await writer.release()
        _ = await active.value

        await syncGate.waitUntilCount(1)
        await syncGate.release()
        #expect(await syncGate.callCount == 1)
    }

    @Test("Recovery resurfaces after a read-only run")
    func recoveryResurfacesAfterRead() async {
        let syncGate = WriteSyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await syncGate.sync() },
            persistRunRecord: { _ in }
        ))
        let active = Task {
            await orchestrator.submit(.observation(
                trigger: .manualCheck,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncGate.waitUntilCount(1)
        let recovery = recoveryRecord()

        await orchestrator.restoreRecovery(recovery)
        await syncGate.release()
        _ = await active.value

        #expect(await orchestrator.currentLifecycle()?.runID == recovery.runID)
        #expect(await orchestrator.currentLifecycle()?.state == .recoverable)
    }

    @Test("Restored recovery discards queued writes")
    func restoredRecoveryDropsQueuedWrites() async {
        let writer = WriteProbe(result: BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: []))
        let syncGate = WriteSyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await syncGate.sync() },
            persistRunRecord: { _ in },
            write: .init(writeFixPlan: { input, _ in try await writer.apply(input: input) })
        ))
        let active = Task {
            await orchestrator.submit(.observation(
                trigger: .manualCheck,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncGate.waitUntilCount(1)
        guard case .queued = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected write to queue behind the read")
            return
        }

        await orchestrator.restoreRecovery(recoveryRecord())
        await syncGate.release()
        _ = await active.value

        #expect(await writer.calls.isEmpty)
    }

    @Test("blocked recovery cannot be resolved")
    func blockedRecoveryRemains() async {
        let writer = WriteProbe(result: BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: []))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            write: .init(writeFixPlan: { input, _ in try await writer.apply(input: input) })
        ))
        let blocked = recoveryRecord(state: .blocked)

        await orchestrator.restoreRecovery(blocked)
        await orchestrator.resolveRecovery(runID: blocked.runID, at: Date(timeIntervalSince1970: 200))

        #expect(await orchestrator.currentLifecycle()?.state == .blocked)
        guard case let .recoverable(snapshot, _) = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected blocked recovery to keep writes gated")
            return
        }
        #expect(snapshot.runID == blocked.runID)
        #expect(snapshot.state == .blocked)
        #expect(await writer.calls.isEmpty)
    }

    @Test("write fails closed when its open record cannot persist")
    func persistenceBlocksWrite() async {
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in throw RecordWriteError() },
            write: .init(writeFixPlan: { input, _ in try await writer.apply(input: input) })
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.failureMessage == "Write run could not start because run history is unavailable")
        #expect(await writer.calls.isEmpty)
    }

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

        guard case .failed = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(await writer.calls.isEmpty)
        #expect(await records.records.last?.workItems.first?.state == .prepared)
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

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable result")
            return
        }
        #expect(snapshot.state == .recoverable)
        #expect(await writer.calls.count == 1)
        #expect(await records.records.last?.recoveryID == recoveryID)
        #expect(await records.records.last?.workItems.first?.state == .attempting)
    }

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

        guard case .recoverable = result else {
            Issue.record("Expected recoverable result")
            return
        }
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
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, checkpoint in
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
        #expect(reason.contains("run history could not be finalized"))
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
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
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

    @Test("Conclusive write failures do not open recovery when terminal persistence fails")
    func failedWriteFinalizationFailure() async throws {
        let records = FailedRunProbe()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, checkpoint in
                    try await checkpoint(.afterVerification([itemID: .failed]))
                    return BatchUpdateResult(
                        entries: [],
                        failedTrackIDs: ["track-1"],
                        errorDescriptions: ["Write was rejected before dispatch"]
                    )
                },
                beginRecoveryHold: {
                    Issue.record("A conclusive failed outcome must not open recovery")
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
        #expect(snapshot.workItems.first?.state == .outcome(.failed))
        #expect(await records.failedAttempts == 1)
        #expect(await orchestrator.currentLifecycle()?.state == .failed)
    }

    @Test("partial write requires recovery when its terminal record cannot persist")
    func partialWriteStoreFailure() async {
        let records = FailingRecordProbe(failingCall: 5)
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            noOpEntries: [],
            failedTrackIDs: ["track-2"],
            errorDescriptions: ["Failed to write genre for track track-2"]
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { input, checkpoint in
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
        #expect(snapshot.state == .recoverable)
        #expect(reason.contains("run history could not be finalized"))
        #expect(reason.contains("Failed to write genre for track track-2"))
        #expect(await writer.calls.count == 1)
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
