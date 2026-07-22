import Foundation

struct CheckpointStoreFailure: LocalizedError, Equatable, Sendable {
    let checkpoint: WorkCheckpoint
    let candidate: RunLifecycleSnapshot
    let durableSnapshot: RunLifecycleSnapshot
    let isWriteAdjacent: Bool

    var errorDescription: String? {
        "Could not persist \(String(describing: checkpoint.boundary)) work checkpoint"
    }
}

extension RunOrchestrator {
    enum RunWorkError: LocalizedError {
        case missingFixPlanProducer
        case missingWriteRunner
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
