import Foundation
import OSLog

public enum RecoveryResolutionOutcome: Equatable, Sendable {
    case resolved
    case rejected
}

extension RunOrchestrator {
    struct RecoveryRun {
        let snapshot: RunLifecycleSnapshot
        let reason: String
        let holdID: UUID
    }

    enum RecoveryCandidate {
        case run(RecoveryRun)
        case hold(UUID)

        var holdID: UUID {
            switch self {
            case let .run(run): run.holdID
            case let .hold(id): id
            }
        }

        var run: RecoveryRun? {
            guard case let .run(run) = self else { return nil }
            return run
        }
    }

    enum RecoveryState {
        case clear
        case pending(RecoveryCandidate)
        case current(RecoveryCandidate)
        case currentThenPending(RecoveryCandidate, RecoveryCandidate)

        var current: RecoveryCandidate? {
            switch self {
            case .clear, .pending: nil
            case let .current(candidate), let .currentThenPending(candidate, _): candidate
            }
        }

        var pending: RecoveryCandidate? {
            switch self {
            case .clear, .current: nil
            case let .pending(candidate), let .currentThenPending(_, candidate): candidate
            }
        }

        var hasWriteBlock: Bool {
            if case .clear = self {
                return false
            }
            return true
        }

        func contains(_ holdID: UUID) -> Bool {
            current?.holdID == holdID || pending?.holdID == holdID
        }
    }

    public func restoreRecovery(_ record: RunRecord) async {
        guard record.intent == .writeFixes,
              record.finishedAt == nil,
              record.state.needsWriteRecovery
        else { return }
        let snapshot = RunLifecycleSnapshot(recovering: record)
        let reason = record.failureMessage ?? "Interrupted write requires Music.app verification."
        let run = RecoveryRun(
            snapshot: snapshot,
            reason: reason,
            holdID: record.recoveryID ?? record.runID.rawValue
        )
        await admitRecovery(.run(run))
    }

    public func restoreRecoveryHold(id: UUID) async {
        await admitRecovery(.hold(id))
    }

    /// Resolves only recoverable holds; blocked records require a separate repair path.
    public func resolveRecovery(runID: RunID, at finishedAt: Date) async -> RecoveryResolutionOutcome {
        guard let current = recoveryState.current,
              current.run?.snapshot.runID == runID
        else { return .rejected }
        return await resolveRecovery(current, runID: runID, at: finishedAt)
    }

    public func resolveRecovery(
        id: UUID,
        runID: RunID?,
        at finishedAt: Date
    ) async -> RecoveryResolutionOutcome {
        guard let current = recoveryState.current, current.holdID == id else {
            return .rejected
        }
        return await resolveRecovery(current, runID: runID, at: finishedAt)
    }

    private func resolveRecovery(
        _ candidate: RecoveryCandidate,
        runID: RunID?,
        at finishedAt: Date
    ) async -> RecoveryResolutionOutcome {
        let resolved: RunLifecycleSnapshot?
        switch candidate {
        case let .run(run):
            guard let closure = recoveryClosure(run, matching: runID, at: finishedAt) else {
                return .rejected
            }
            resolved = closure
        case .hold:
            resolved = nil
        }

        if let clearHold = dependencies.write?.clearRecoveryHold {
            do {
                try await clearHold(candidate.holdID)
            } catch {
                log.error("Recovery hold clearance failed: \(error.localizedDescription, privacy: .private)")
                return .rejected
            }
        }

        switch recoveryState {
        case let .current(current) where current.holdID == candidate.holdID:
            recoveryState = .clear
        case let .currentThenPending(current, pending) where current.holdID == candidate.holdID:
            recoveryState = .pending(pending)
        case .clear, .pending, .current, .currentThenPending:
            log.error("Recovery state changed before logical clearance committed")
            return .rejected
        }

        if let resolved, activeRun == nil {
            latestRun = resolved
            broadcast(resolved)
        }
        await promotePending()
        return .resolved
    }

    private func recoveryClosure(
        _ run: RecoveryRun,
        matching runID: RunID?,
        at finishedAt: Date
    ) -> RunLifecycleSnapshot? {
        guard runID == nil || run.snapshot.runID == runID else { return nil }
        guard case .suspended(.recoverable) = run.snapshot.phase else { return nil }

        do {
            return try run.snapshot
                .beginningRecovery()
                .dismissingOpenWork()
                .cancelling(
                    message: "Recovery closed after Music.app verification.",
                    at: finishedAt
                )
        } catch {
            log.error("Recovery work closure failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func admitRecovery(_ candidate: RecoveryCandidate) async {
        guard !recoveryState.contains(candidate.holdID) else { return }
        discardPendingWrites()

        switch recoveryState {
        case .clear:
            if activeRun?.intent == .writeFixes {
                recoveryState = .pending(candidate)
            } else {
                await activateRecovery(candidate)
            }
        case let .current(current):
            recoveryState = .currentThenPending(current, candidate)
        case .pending, .currentThenPending:
            log.error("""
            Recovery hold \(candidate.holdID.uuidString, privacy: .public) remains persisted because the pending \
            recovery slot is occupied
            """)
        }
    }

    private func activateRecovery(_ candidate: RecoveryCandidate) async {
        recoveryState = .current(candidate)
        if let restoreHold = dependencies.write?.restoreRecoveryHold {
            let activeID = await restoreHold(candidate.holdID)
            if activeID != candidate.holdID {
                log.error("""
                Recovery hold identity mismatch: requested \(candidate.holdID.uuidString, privacy: .public), active \
                \(activeID.uuidString, privacy: .public)
                """)
                recoveryState = .currentThenPending(.hold(activeID), candidate)
                return
            }
        }
        guard activeRun == nil, let run = candidate.run else { return }
        latestRun = run.snapshot
        broadcast(run.snapshot)
    }

    func promotePending() async {
        guard case let .pending(candidate) = recoveryState else { return }
        await activateRecovery(candidate)
    }

    func installLiveRecovery(_ run: RecoveryRun) {
        let candidate = RecoveryCandidate.run(run)
        switch recoveryState {
        case .clear:
            recoveryState = .current(candidate)
        case let .pending(pending):
            recoveryState = .currentThenPending(candidate, pending)
        case let .current(current):
            log.error("Live writer recovery replaced an unexpected current recovery")
            recoveryState = .currentThenPending(candidate, current)
        case let .currentThenPending(current, _):
            log.error("Live writer recovery found both current and pending recovery state")
            recoveryState = .currentThenPending(candidate, current)
        }
    }
}
