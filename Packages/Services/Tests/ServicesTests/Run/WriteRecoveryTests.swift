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
            writeFixPlan: { try await writer.apply(input: $0) },
            beginRecoveryHold: { recoveryID },
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
            writeFixPlan: { try await writer.apply(input: $0) },
            beginRecoveryHold: { UUID() }
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
            writeFixPlan: { try await writer.apply(input: $0) }
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
            writeFixPlan: { try await writer.apply(input: $0) }
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
            writeFixPlan: { try await writer.apply(input: $0) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed result")
            return
        }
        #expect(snapshot.failureMessage == "Write run could not start because run history is unavailable")
        #expect(await writer.calls.isEmpty)
    }

    @Test("write fails when its terminal record cannot persist")
    func failsUnstoredTerminal() async throws {
        let records = TerminalRecordProbe()
        let recoveryID = UUID()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            writeFixPlan: { try await writer.apply(input: $0) },
            beginRecoveryHold: { recoveryID }
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

    @Test("partial write requires recovery when its terminal record cannot persist")
    func partialWriteStoreFailure() async {
        let records = TerminalRecordProbe()
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
            writeFixPlan: { try await writer.apply(input: $0) },
            beginRecoveryHold: { recoveryID }
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
