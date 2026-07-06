import Foundation
import OSLog

private let log = Logger(subsystem: "com.genreupdater", category: "RunLifecycle")

/// Wire vocabulary for run lifecycle states.
///
/// Raw values are persisted in `PersistedRunRecord.stateRaw` and the transitions
/// blob; never rename cases. In-memory consumers should switch on `RunPhase`
/// instead of this flat enum.
public enum RunLifecycleState: String, Codable, Equatable, Sendable {
    case created
    case syncingLibrary
    case planningFixes
    case reporting
    case completed
    case completedNoOp
    case failed
}

public enum RunActiveStage: Equatable, Sendable {
    case created
    case syncingLibrary
    case planningFixes
    case reporting
}

public enum RunOutcome: Equatable, Sendable {
    case completed(SyncResult)
    case completedNoOp(SyncResult)
    case failed(message: String)
}

public enum RunPhase: Equatable, Sendable {
    case active(RunActiveStage)
    case finished(RunOutcome, finishedAt: Date)

    /// The ONLY place phase maps to wire vocabulary.
    public var state: RunLifecycleState {
        switch self {
        case .active(.created): .created
        case .active(.syncingLibrary): .syncingLibrary
        case .active(.planningFixes): .planningFixes
        case .active(.reporting): .reporting
        case .finished(.completed, _): .completed
        case .finished(.completedNoOp, _): .completedNoOp
        case .finished(.failed, _): .failed
        }
    }
}

public struct RunLifecycleSnapshot: Equatable, Sendable {
    public let runID: RunID
    public let requestID: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let scope: ProcessingScopeSnapshot
    public let startedAt: Date
    public let phase: RunPhase

    public var state: RunLifecycleState {
        phase.state
    }

    public var isActive: Bool {
        if case .active = phase { true } else { false }
    }

    public var finishedAt: Date? {
        if case let .finished(_, finishedAt) = phase { finishedAt } else { nil }
    }

    public var syncResult: SyncResult? {
        switch phase {
        case let .finished(.completed(result), _), let .finished(.completedNoOp(result), _): result
        case .active, .finished(.failed, _): nil
        }
    }

    public var failureMessage: String? {
        if case let .finished(.failed(message), _) = phase { message } else { nil }
    }

    public init(
        runID: RunID,
        requestID: RunRequestID,
        trigger: RunTrigger,
        intent: RunIntent,
        scope: ProcessingScopeSnapshot,
        startedAt: Date,
        phase: RunPhase
    ) {
        self.runID = runID
        self.requestID = requestID
        self.trigger = trigger
        self.intent = intent
        self.scope = scope
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

    public func beginningReporting() -> Self {
        if phase != .active(.syncingLibrary), phase != .active(.planningFixes) {
            reportIllegalTransition(
                "beginningReporting()",
                expected: ".active(.syncingLibrary) or .active(.planningFixes)"
            )
        }
        return withPhase(.active(.reporting))
    }

    public func finishing(result: SyncResult, at finishedAt: Date) -> Self {
        finishing(result: result, hasActionableWork: result.hasChanges, at: finishedAt)
    }

    public func finishing(result: SyncResult, hasActionableWork: Bool, at finishedAt: Date) -> Self {
        if phase != .active(.reporting) {
            reportIllegalTransition("finishing(result:hasActionableWork:at:)", expected: ".active(.reporting)")
        }
        let outcome: RunOutcome = hasActionableWork ? .completed(result) : .completedNoOp(result)
        return withPhase(.finished(outcome, finishedAt: finishedAt))
    }

    public func failing(message: String, at finishedAt: Date) -> Self {
        if case .active = phase {} else {
            reportIllegalTransition("failing(message:at:)", expected: "an active phase")
        }
        return withPhase(.finished(.failed(message: message), finishedAt: finishedAt))
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
            startedAt: startedAt,
            phase: phase
        )
    }
}

public enum RunSubmissionResult: Equatable, Sendable {
    case alreadyRunning(RunLifecycleSnapshot)
    case completed(RunLifecycleSnapshot)
    case completedNoOp(RunLifecycleSnapshot)
    case failed(RunLifecycleSnapshot)

    public var lifecycle: RunLifecycleSnapshot {
        switch self {
        case let .alreadyRunning(snapshot),
             let .completed(snapshot),
             let .completedNoOp(snapshot),
             let .failed(snapshot):
            snapshot
        }
    }
}
