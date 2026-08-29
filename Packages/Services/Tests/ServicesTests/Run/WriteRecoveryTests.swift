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
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            write: .init(
                writeFixPlan: { input, _, checkpoint in
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

        _ = await orchestrator.resolveRecovery(
            runID: snapshot.runID,
            at: Date(timeIntervalSince1970: 200),
            observedOutcomes: Dictionary(uniqueKeysWithValues: firstInput.workItems.map { item in
                (item.id, ObservedWorkOutcome(outcome: .failed, observedValue: nil))
            })
        )
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
            synchronizeLibrary: { _ in await syncGate.sync() },
            persistRunRecord: { _ in },
            write: .init(
                writeFixPlan: { input, _, checkpoint in
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
            synchronizeLibrary: { _ in await syncGate.sync() },
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
            synchronizeLibrary: { _ in await syncGate.sync() },
            persistRunRecord: { _ in },
            write: .init(writeFixPlan: { input, _, _ in try await writer.apply(input: input) })
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

    @Test("resolved recovery closes restored work with observed outcomes")
    func closesRestoredWork() async {
        let attempted = makeWorkItem(state: .attempted)
        let recovery = recoveryRecord(workItems: [attempted])
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { _ in
                // Persistence is inert because this test observes only in-memory recovery closure.
            }
        ))

        await orchestrator.restoreRecovery(recovery)
        _ = await orchestrator.resolveRecovery(
            runID: recovery.runID,
            at: Date(timeIntervalSince1970: 200),
            observedOutcomes: [attempted.id: ObservedWorkOutcome(outcome: .written, observedValue: "Metal")]
        )

        let resolved = await orchestrator.currentLifecycle()
        #expect(resolved?.state == .cancelled)
        #expect(resolved?.hasOpenItems == false)
        #expect(resolved?.workItems.first?.state == .outcome(.written))
    }

    @Test("blocked recovery cannot be resolved")
    func blockedRecoveryRemains() async {
        let writer = WriteProbe(result: BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: []))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { _ in },
            write: .init(writeFixPlan: { input, _, _ in try await writer.apply(input: input) })
        ))
        let blocked = recoveryRecord(state: .blocked)

        await orchestrator.restoreRecovery(blocked)
        _ = await orchestrator.resolveRecovery(runID: blocked.runID, at: Date(timeIntervalSince1970: 200))

        #expect(await orchestrator.currentLifecycle()?.state == .blocked)
        guard case let .recoverable(snapshot, _) = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected blocked recovery to keep writes gated")
            return
        }
        #expect(snapshot.runID == blocked.runID)
        #expect(snapshot.state == .blocked)
        #expect(await writer.calls.isEmpty)
    }
}
