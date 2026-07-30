import Core
import Foundation

/// Public only as a thrown-error payload; members stay internal.
public struct CheckpointStoreFailure: LocalizedError, Equatable, Sendable {
    let checkpoint: WorkCheckpoint
    let candidate: RunLifecycleSnapshot
    let durableSnapshot: RunLifecycleSnapshot
    let isWriteAdjacent: Bool
    let reason: String
    let completion: ScriptCompletion?

    init(
        checkpoint: WorkCheckpoint,
        candidate: RunLifecycleSnapshot,
        durableSnapshot: RunLifecycleSnapshot,
        isWriteAdjacent: Bool,
        reason: String,
        completion: ScriptCompletion? = nil
    ) {
        self.checkpoint = checkpoint
        self.candidate = candidate
        self.durableSnapshot = durableSnapshot
        self.isWriteAdjacent = isWriteAdjacent
        self.reason = reason
        self.completion = completion
    }

    public var errorDescription: String? {
        "Could not persist \(String(describing: checkpoint.boundary)) work checkpoint: \(reason)"
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.checkpoint == rhs.checkpoint
            && lhs.candidate == rhs.candidate
            && lhs.durableSnapshot == rhs.durableSnapshot
            && lhs.isWriteAdjacent == rhs.isWriteAdjacent
            && lhs.reason == rhs.reason
            && lhs.completion === rhs.completion
    }

    func withOutcome(_ outcome: AppleScriptOutcomeError) -> Self {
        Self(
            checkpoint: checkpoint,
            candidate: candidate,
            durableSnapshot: durableSnapshot,
            isWriteAdjacent: isWriteAdjacent,
            reason: "\(reason). \(outcome.localizedDescription)",
            completion: outcome.completion
        )
    }
}

extension WriteAttemptFailure {
    var reportedError: any Error {
        guard let outcome = writeError as? AppleScriptOutcomeError else {
            return checkpointError
        }
        if case let WorkCheckpointError.store(failure) = checkpointError {
            return WorkCheckpointError.store(failure.withOutcome(outcome))
        }
        // The unknown outcome wins over a non-store checkpoint error: it
        // carries the ScriptCompletion (when the script is still pending) that
        // recovery awaits before allowing another physical write (mirrors
        // AppleScriptBridge.recordUnknownAttempt).
        return outcome
    }
}

extension RunOrchestrator {
    enum RunWorkError: LocalizedError {
        case missingFixPlanProducer
        case missingWriteRunner
        case recoveryPending
        case writeFailure(
            failedOperationCount: Int,
            failedTrackCount: Int,
            reasons: [String],
            isPartial: Bool
        )

        var errorDescription: String? {
            switch self {
            case .missingFixPlanProducer:
                "Fix plan producer is unavailable"
            case .missingWriteRunner:
                "Fix plan write runner is unavailable"
            case .recoveryPending:
                "A restored recovery hold blocks the next write attempt"
            case let .writeFailure(failedOperationCount, failedTrackCount, reasons, isPartial):
                Self.writeFailureDescription(
                    failedOperationCount: failedOperationCount,
                    failedTrackCount: failedTrackCount,
                    reasons: reasons,
                    isPartial: isPartial
                )
            }
        }

        private static func writeFailureDescription(
            failedOperationCount: Int,
            failedTrackCount: Int,
            reasons: [String],
            isPartial: Bool
        ) -> String {
            let failureKind = isPartial ? "partially failed" : "failed"
            let summary = "Write run \(failureKind): \(failedOperationCount) operations failed across " +
                "\(failedTrackCount) tracks"
            let details = reasons.filter { !$0.isEmpty }.joined(separator: "; ")
            return details.isEmpty ? summary : "\(summary). Errors: \(details)"
        }
    }
}
