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
            persistRunRecord: skipPersistence,
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) },
                clearRecoveryHold: { try await holds.clear($0) }
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
            persistRunRecord: skipPersistence,
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) },
                clearRecoveryHold: { try await holds.clear($0) }
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
            persistRunRecord: skipPersistence,
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) },
                clearRecoveryHold: { try await holds.clear($0) }
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

        #expect(
            await orchestrator.resolveRecovery(
                runID: live.runID,
                at: Date(timeIntervalSince1970: 200)
            ) == .resolved
        )

        #expect(await holds.restoredIDs == [recoveryID])
        #expect(await holds.clearedIDs.count == 1)
        #expect(await orchestrator.currentLifecycle()?.runID == recovery.runID)
    }

    @Test("hold-only recovery uses deferred exact-ID admission")
    func defersRecoveryHold() async {
        let gate = AttemptGate(pause: .beforeAttempt, finish: .completed)
        let holds = HoldProbe()
        let recoveryID = UUID()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: skipPersistence,
            write: .init(
                writeFixPlan: { input, checkpoint in
                    try await gate.run(input: input, checkpoint: checkpoint)
                },
                beginRecoveryHold: { await holds.beginLive() },
                restoreRecoveryHold: { await holds.restore($0) },
                clearRecoveryHold: { try await holds.clear($0) }
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

        #expect(
            await orchestrator.resolveRecovery(
                id: recoveryID,
                runID: nil,
                at: Date(timeIntervalSince1970: 200)
            ) == .resolved
        )
        #expect(await holds.restoredIDs == [recoveryID])
    }

    @Test("authoritative hold stays current before the requested recovery")
    func keepsAuthoritativeHold() async {
        let requestedID = UUID()
        let authoritativeID = UUID()
        let holds = HoldProbe(activeID: authoritativeID)
        let orchestrator = makeHoldOrchestrator(holds)

        await orchestrator.restoreRecoveryHold(id: requestedID)

        #expect(
            await orchestrator.resolveRecovery(
                id: requestedID,
                runID: nil,
                at: Date(timeIntervalSince1970: 200)
            ) == .rejected
        )
        #expect(
            await orchestrator.resolveRecovery(
                id: authoritativeID,
                runID: nil,
                at: Date(timeIntervalSince1970: 201)
            ) == .resolved
        )
        #expect(await holds.clearedIDs == [authoritativeID])
        #expect(await holds.restoredIDs == [requestedID, requestedID])
        #expect(await holds.activeID == requestedID)
        guard case .recoveryRequired = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected the promoted requested hold to block writes")
            return
        }
    }

    @Test("physical clear keeps logical write admission blocked")
    func blocksDuringClear() async {
        let recoveryID = UUID()
        let holds = HoldProbe()
        let orchestrator = makeHoldOrchestrator(holds)
        await orchestrator.restoreRecoveryHold(id: recoveryID)
        await holds.pauseClear()
        let resolution = Task {
            await orchestrator.resolveRecovery(
                id: recoveryID,
                runID: nil,
                at: Date(timeIntervalSince1970: 200)
            )
        }
        await holds.waitUntilPaused()

        guard case .recoveryRequired = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            await holds.releaseClear()
            _ = await resolution.value
            Issue.record("Expected physical clear to retain the logical write gate")
            return
        }

        await holds.releaseClear()
        #expect(await resolution.value == .resolved)
    }

    @Test("invalid recovery closure retains both write gates")
    func rejectsInvalidClosure() async {
        let recoveryID = UUID()
        let item = makeWorkItem(state: .prepared)
        let holds = HoldProbe()
        let orchestrator = makeHoldOrchestrator(holds)
        let recovery = recoveryRecord(
            workItems: [item, item],
            recoveryID: recoveryID
        )
        await orchestrator.restoreRecovery(recovery)

        #expect(
            await orchestrator.resolveRecovery(
                runID: recovery.runID,
                at: Date(timeIntervalSince1970: 200)
            ) == .rejected
        )
        #expect(await holds.clearedIDs.isEmpty)
        #expect(await holds.activeID == recoveryID)
        guard case let .recoverable(snapshot, _) = await orchestrator.submit(.manualWrite(input: writeInput())) else {
            Issue.record("Expected rejected recovery closure to keep writes blocked")
            return
        }
        #expect(snapshot.runID == recovery.runID)
    }
}

private let skipPersistence: @Sendable (RunRecord) async throws -> Void = { _ in
    // These tests exercise live recovery admission, not record persistence.
}

private func makeHoldOrchestrator(_ holds: HoldProbe) -> RunOrchestrator {
    RunOrchestrator(dependencies: .init(
        synchronizeLibrary: { SyncResult() },
        persistRunRecord: skipPersistence,
        write: .init(
            restoreRecoveryHold: { await holds.restore($0) },
            clearRecoveryHold: { try await holds.clear($0) }
        )
    ))
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
    private(set) var activeID: UUID?
    private(set) var liveCount = 0
    private(set) var restoredIDs: [UUID] = []
    private(set) var clearedIDs: [UUID] = []
    private var shouldPauseClear = false
    private var isClearPaused = false
    private var clearPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearReleaseWaiter: CheckedContinuation<Void, Never>?

    init(activeID: UUID? = nil) {
        self.activeID = activeID
    }

    func beginLive() -> UUID {
        if let activeID {
            return activeID
        }
        liveCount += 1
        activeID = liveID
        return liveID
    }

    func restore(_ id: UUID) -> UUID {
        restoredIDs.append(id)
        if let activeID {
            return activeID
        }
        activeID = id
        return id
    }

    func clear(_ id: UUID) async throws {
        guard activeID == id else {
            throw HoldProbeError.wrongID
        }
        if shouldPauseClear {
            isClearPaused = true
            clearPauseWaiters.forEach { $0.resume() }
            clearPauseWaiters = []
            await withCheckedContinuation { clearReleaseWaiter = $0 }
        }
        activeID = nil
        clearedIDs.append(id)
    }

    func pauseClear() {
        shouldPauseClear = true
    }

    func waitUntilPaused() async {
        if isClearPaused {
            return
        }
        await withCheckedContinuation { clearPauseWaiters.append($0) }
    }

    func releaseClear() {
        shouldPauseClear = false
        clearReleaseWaiter?.resume()
        clearReleaseWaiter = nil
    }
}

private enum HoldProbeError: Error {
    case wrongID
}
