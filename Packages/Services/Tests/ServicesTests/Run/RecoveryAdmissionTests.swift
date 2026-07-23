import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator recovery admission")
struct RecoveryAdmissionTests {
    @Test("restored recovery waits for an active writer and fences its next attempt")
    func defersRestoredRecovery() async {
        let gate = AttemptGate(pause: .beforeAttempt, finish: .completed)
        let holds = HoldProbe()
        let recoveryID = UUID()
        let recovery = recoveryRecord(recoveryID: recoveryID)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) }
            )
        ))
        let active = Task { await orchestrator.submit(.manualWrite(input: writeInput())) }
        await gate.waitUntilPaused()

        await orchestrator.restoreRecovery(recovery)

        #expect(await holds.restoredIDs.isEmpty)
        guard case .recoveryRequired = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected pending recovery to reject another write")
            return
        }
        await gate.release()
        guard case .failed = await active.value else {
            Issue.record("Expected the fenced writer to fail before its attempt")
            return
        }
        #expect(await holds.liveCount == 0)
        #expect(await holds.restoredIDs == [recoveryID])
        #expect(await orchestrator.currentLifecycle()?.runID == recovery.runID)
    }

    @Test("restored recovery lets an admitted attempt finish before promotion")
    func finishesAdmittedAttempt() async {
        let gate = AttemptGate(pause: .afterAdmission, finish: .completed)
        let holds = HoldProbe()
        let recoveryID = UUID()
        let recovery = recoveryRecord(recoveryID: recoveryID)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) }
            )
        ))
        let active = Task { await orchestrator.submit(.manualWrite(input: writeInput())) }
        await gate.waitUntilPaused()

        await orchestrator.restoreRecovery(recovery)
        #expect(await holds.restoredIDs.isEmpty)
        await gate.release()

        guard case .completed = await active.value else {
            Issue.record("Expected the admitted attempt to complete")
            return
        }
        #expect(await holds.liveCount == 0)
        #expect(await holds.restoredIDs == [recoveryID])
        #expect(await orchestrator.currentLifecycle()?.runID == recovery.runID)
    }

    @Test("live writer recovery stays current before restored recovery")
    func keepsLiveRecoveryFirst() async {
        let gate = AttemptGate(pause: .afterAdmission, finish: .unknown)
        let holds = HoldProbe()
        let recoveryID = UUID()
        let recovery = recoveryRecord(recoveryID: recoveryID)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) }
            )
        ))
        let active = Task { await orchestrator.submit(.manualWrite(input: writeInput())) }
        await gate.waitUntilPaused()

        await orchestrator.restoreRecovery(recovery)
        await gate.release()

        guard case let .recoverable(live, _) = await active.value else {
            Issue.record("Expected live writer recovery")
            return
        }
        #expect(await holds.liveCount == 1)
        #expect(await holds.restoredIDs.isEmpty)
        #expect(await orchestrator.currentLifecycle()?.runID == live.runID)

        await orchestrator.resolveRecovery(runID: live.runID, at: Date(timeIntervalSince1970: 200))

        #expect(await holds.restoredIDs == [recoveryID])
        #expect(await orchestrator.currentLifecycle()?.runID == recovery.runID)
    }

    @Test("hold-only recovery uses deferred exact-ID admission")
    func defersRecoveryHold() async {
        let gate = AttemptGate(pause: .beforeAttempt, finish: .completed)
        let holds = HoldProbe()
        let recoveryID = UUID()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) }
            )
        ))
        let active = Task { await orchestrator.submit(.manualWrite(input: writeInput())) }
        await gate.waitUntilPaused()

        await orchestrator.restoreRecoveryHold(id: recoveryID)
        #expect(await holds.restoredIDs.isEmpty)
        await gate.release()
        _ = await active.value

        #expect(await holds.restoredIDs == [recoveryID])
        guard case .recoveryRequired = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected the exact hold to keep writes blocked")
            return
        }

        await orchestrator.resolveRecovery(id: recoveryID, runID: nil, at: Date(timeIntervalSince1970: 200))
        #expect(await holds.restoredIDs == [recoveryID])
    }
}

private actor AttemptGate {
    enum PausePoint: Equatable {
        case beforeAttempt
        case afterAdmission
    }

    enum Finish {
        case completed
        case unknown
    }

    private let pausePoint: PausePoint
    private let finish: Finish
    private var isPaused = false
    private var isReleased = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(pause: PausePoint, finish: Finish) {
        pausePoint = pause
        self.finish = finish
    }

    func run(
        input: FixPlanWriteInput,
        checkpoint: WorkCheckpointSink
    ) async throws -> BatchUpdateResult {
        let itemIDs = input.workItems.map(\.id)
        if pausePoint == .beforeAttempt {
            await pause()
        }
        try await checkpoint(.beforeAttempt(itemIDs))
        if pausePoint == .afterAdmission {
            await pause()
        }

        switch finish {
        case .completed:
            try await checkpoint(.afterAttempt(itemIDs))
            try await checkpoint(.afterVerification(Dictionary(
                uniqueKeysWithValues: itemIDs.map { ($0, WorkOutcome.written) }
            )))
            return BatchUpdateResult(entries: [writeEntry()], failedTrackIDs: [], errorDescriptions: [])
        case .unknown:
            throw AppleScriptOutcomeError(
                scriptName: "update_property",
                reason: "connection ended before reply"
            )
        }
    }

    func waitUntilPaused() async {
        if isPaused {
            return
        }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func pause() async {
        isPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters = []
        if isReleased {
            return
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}

private actor HoldProbe {
    private let liveID = UUID()
    private(set) var liveCount = 0
    private(set) var restoredIDs: [UUID] = []

    func beginLive() -> UUID {
        liveCount += 1
        return liveID
    }

    func restore(_ id: UUID) -> UUID {
        restoredIDs.append(id)
        return id
    }
}
