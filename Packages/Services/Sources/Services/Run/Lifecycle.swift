import Foundation
import OSLog

private let log = Logger(subsystem: "com.genreupdater", category: "RunLifecycle")

/// Wire vocabulary for run lifecycle states.
///
/// Raw values are persisted in `PersistedRunRecord.stateRaw` and the transitions
/// blob; never rename cases. In-memory consumers should switch on `RunPhase`
/// instead of this flat enum.
public enum RunLifecycleState: String, CaseIterable, Codable, Equatable, Sendable {
    case created
    case queued
    case syncingLibrary
    case analyzingDelta
    case planningFixes
    case awaitingReview
    case writing
    case verifying
    case reporting
    case completed
    case completedNoOp
    case blocked
    case failed
    case cancelled
    case recoverable
    case recovering
}

public enum RunActiveStage: Equatable, Sendable {
    case created
    case queued
    case syncingLibrary
    case analyzingDelta
    case planningFixes
    case awaitingReview
    case writing
    case verifying
    case reporting
    case recovering
}

public enum RunSuspendedState: Equatable, Sendable {
    case blocked
    case recoverable
}

public enum RunOutcome: Equatable, Sendable {
    case completed(SyncResult)
    /// The run finished without actionable work for its intent. The associated
    /// sync result can still contain library changes; consumers that need sync
    /// deltas should inspect the result instead of inferring from this state.
    case completedNoOp(SyncResult)
    case failed(message: String)
    case cancelled(message: String)
}

public enum RunPhase: Equatable, Sendable {
    case active(RunActiveStage)
    case suspended(RunSuspendedState)
    case finished(RunOutcome, finishedAt: Date)

    /// The ONLY place phase maps to wire vocabulary.
    public var state: RunLifecycleState {
        switch self {
        case .active(.created): .created
        case .active(.queued): .queued
        case .active(.syncingLibrary): .syncingLibrary
        case .active(.analyzingDelta): .analyzingDelta
        case .active(.planningFixes): .planningFixes
        case .active(.awaitingReview): .awaitingReview
        case .active(.writing): .writing
        case .active(.verifying): .verifying
        case .active(.reporting): .reporting
        case .active(.recovering): .recovering
        case .suspended(.blocked): .blocked
        case .suspended(.recoverable): .recoverable
        case .finished(.completed, _): .completed
        case .finished(.completedNoOp, _): .completedNoOp
        case .finished(.failed, _): .failed
        case .finished(.cancelled, _): .cancelled
        }
    }
}

public struct RunLifecycleSnapshot: Equatable, Sendable {
    public let runID: RunID
    public let requestID: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let scope: ProcessingScopeSnapshot
    public let writeTarget: FixPlanWriteTarget?
    public let startedAt: Date
    public let phase: RunPhase

    public var state: RunLifecycleState {
        phase.state
    }

    public var isActive: Bool {
        if case .active = phase {
            true
        } else {
            false
        }
    }

    var canQueueManual: Bool {
        guard isActive else { return false }
        switch trigger {
        case .backgroundSync, .fileSystemEvent:
            return true
        case .manualCheck, .recovery:
            return false
        }
    }

    public var finishedAt: Date? {
        if case let .finished(_, finishedAt) = phase {
            finishedAt
        } else {
            nil
        }
    }

    public var syncResult: SyncResult? {
        switch phase {
        case let .finished(.completed(result), _), let .finished(.completedNoOp(result), _): result
        case .active, .suspended, .finished(.failed, _), .finished(.cancelled, _): nil
        }
    }

    public var failureMessage: String? {
        if case let .finished(.failed(message), _) = phase {
            message
        } else if case let .finished(.cancelled(message), _) = phase {
            message
        } else {
            nil
        }
    }

    public init(
        runID: RunID,
        requestID: RunRequestID,
        trigger: RunTrigger,
        intent: RunIntent,
        scope: ProcessingScopeSnapshot,
        writeTarget: FixPlanWriteTarget? = nil,
        startedAt: Date,
        phase: RunPhase
    ) {
        self.runID = runID
        self.requestID = requestID
        self.trigger = trigger
        self.intent = intent
        self.scope = scope
        self.writeTarget = writeTarget
        self.startedAt = startedAt
        self.phase = phase
    }

    public func beginningSync() -> Self {
        if phase != .active(.created) {
            reportIllegalTransition("beginningSync()", expected: ".active(.created)")
        }
        return withPhase(.active(.syncingLibrary))
    }

    public func beginningFixPlanning() -> Self {
        if phase != .active(.syncingLibrary) {
            reportIllegalTransition("beginningFixPlanning()", expected: ".active(.syncingLibrary)")
        }
        return withPhase(.active(.planningFixes))
    }

    public func beginningWriting() -> Self {
        if phase != .active(.syncingLibrary) {
            reportIllegalTransition("beginningWriting()", expected: ".active(.syncingLibrary)")
        }
        return withPhase(.active(.writing))
    }

    public func beginningVerifying() -> Self {
        if phase != .active(.writing) {
            reportIllegalTransition("beginningVerifying()", expected: ".active(.writing)")
        }
        return withPhase(.active(.verifying))
    }

    public func beginningReporting() -> Self {
        if phase != .active(.syncingLibrary),
           phase != .active(.planningFixes),
           phase != .active(.writing),
           phase != .active(.verifying) {
            reportIllegalTransition(
                "beginningReporting()",
                expected: ".active(.syncingLibrary), .active(.planningFixes), .active(.writing), or .active(.verifying)"
            )
        }
        return withPhase(.active(.reporting))
    }

    public func finishing(result: SyncResult, at finishedAt: Date) -> Self {
        finishing(result: result, hasActionableWork: result.hasChanges, at: finishedAt)
    }

    /// Finishes the run using intent-specific actionable-work semantics.
    /// Observation runs normally pass `result.hasChanges`; preview and write
    /// runs pass whether a plan or write outcome did useful work.
    public func finishing(result: SyncResult, hasActionableWork: Bool, at finishedAt: Date) -> Self {
        if phase != .active(.reporting) {
            reportIllegalTransition("finishing(result:hasActionableWork:at:)", expected: ".active(.reporting)")
        }
        let outcome: RunOutcome = hasActionableWork ? .completed(result) : .completedNoOp(result)
        return withPhase(.finished(outcome, finishedAt: finishedAt))
    }

    public func failing(message: String, at finishedAt: Date) -> Self {
        guard case .active = phase else {
            reportIllegalTransition("failing(message:at:)", expected: "an active phase")
            return withPhase(.finished(.failed(message: message), finishedAt: finishedAt))
        }
        return withPhase(.finished(.failed(message: message), finishedAt: finishedAt))
    }

    public func cancelling(message: String, at finishedAt: Date) -> Self {
        guard case .active = phase else {
            reportIllegalTransition("cancelling(message:at:)", expected: "an active phase")
            return withPhase(.finished(.cancelled(message: message), finishedAt: finishedAt))
        }
        return withPhase(.finished(.cancelled(message: message), finishedAt: finishedAt))
    }

    /// assertionFailure alone compiles to a no-op in Release, so a violated
    /// invariant would leave no trail in shipped builds; the log line keeps the
    /// evidence. Only the wire-state name is logged: interpolating the full
    /// phase would dump SyncResult payloads into the log.
    private func reportIllegalTransition(_ transition: String, expected: String) {
        assertionFailure("\(transition) expected phase \(expected), got \(phase)")
        log.error("""
        Run lifecycle invariant violated: \(transition, privacy: .public) expected \
        \(expected, privacy: .public), got \(phase.state.rawValue, privacy: .public)
        """)
    }

    private func withPhase(_ phase: RunPhase) -> Self {
        Self(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: intent,
            scope: scope,
            writeTarget: writeTarget,
            startedAt: startedAt,
            phase: phase
        )
    }
}

public enum RunSubmissionResult: Equatable, Sendable {
    case alreadyCovered(activeRun: RunLifecycleSnapshot)
    case queued(activeRun: RunLifecycleSnapshot)
    case completed(RunLifecycleSnapshot)
    case completedNoOp(RunLifecycleSnapshot)
    case failed(RunLifecycleSnapshot)
    case cancelled(RunLifecycleSnapshot)

    /// The run snapshot associated with this response. For `alreadyCovered`
    /// and `queued`, this is the active run that covered or delayed the request.
    public var lifecycle: RunLifecycleSnapshot {
        switch self {
        case let .alreadyCovered(snapshot),
             let .queued(snapshot),
             let .completed(snapshot),
             let .completedNoOp(snapshot),
             let .failed(snapshot),
             let .cancelled(snapshot):
            snapshot
        }
    }
}
