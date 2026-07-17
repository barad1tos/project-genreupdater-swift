import Foundation
import OSLog

private let recoveryLog = Logger(subsystem: "com.genreupdater", category: "RecoveryPreflight")

public enum RecoveryPreflightResolution: Equatable, Sendable {
    case recordMissing
    case alreadyFinished
}

public enum RecoveryPreflightAttention: Equatable, Sendable {
    case writeAdjacentState(RunLifecycleState)
    case unresolvedState(RunLifecycleState)
    case unsupportedPayload
}

public enum RecoveryPreflightBlocker: Equatable, Sendable {
    case storeUnavailable
}

public enum RecoveryPreflightOutcome: Equatable, Sendable {
    case resolved(runID: RunID, reason: RecoveryPreflightResolution)
    case inspectable(runID: RunID, state: RunLifecycleState)
    case needsAttention(runID: RunID, reason: RecoveryPreflightAttention)
    case blocked(runID: RunID, reason: RecoveryPreflightBlocker)
}

public enum RecoveryPreflight {
    public static func classify(_ record: RunRecord) -> RecoveryPreflightOutcome {
        guard record.finishedAt == nil else {
            return .resolved(runID: record.runID, reason: .alreadyFinished)
        }

        switch record.state {
        case .created,
             .queued,
             .syncingLibrary,
             .analyzingDelta,
             .planningFixes,
             .awaitingReview:
            return .inspectable(runID: record.runID, state: record.state)
        case .writing,
             .verifying:
            return .needsAttention(runID: record.runID, reason: .writeAdjacentState(record.state))
        case .reporting:
            if record.intent == .writeFixes {
                return .needsAttention(runID: record.runID, reason: .writeAdjacentState(record.state))
            }
            return .inspectable(runID: record.runID, state: record.state)
        case .blocked,
             .recoverable,
             .recovering:
            return .needsAttention(runID: record.runID, reason: .unresolvedState(record.state))
        case .completed,
             .completedNoOp,
             .failed,
             .cancelled:
            return .resolved(runID: record.runID, reason: .alreadyFinished)
        }
    }
}

public struct RecoveryPreflightService: Sendable {
    private let store: any RunRecordStore

    public init(store: any RunRecordStore) {
        self.store = store
    }

    public func run(for runID: RunID) async -> RecoveryPreflightOutcome {
        do {
            guard let record = try await store.record(for: runID) else {
                return .resolved(runID: runID, reason: .recordMissing)
            }
            return RecoveryPreflight.classify(record)
        } catch {
            recoveryLog.error("""
            Recovery preflight failed for run \(runID.rawValue.uuidString, privacy: .public): \
            \(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private)
            """)
            return .blocked(runID: runID, reason: .storeUnavailable)
        }
    }
}
