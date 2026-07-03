import Foundation

public enum RunLifecycleState: String, Codable, Equatable, Sendable {
    case created
    case syncingLibrary
    case reporting
    case completed
    case completedNoOp
    case failed
}

public struct RunLifecycleSnapshot: Equatable, Sendable {
    public let runID: RunID
    public let requestID: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let state: RunLifecycleState
    public let scope: ProcessingScopeSnapshot
    public let syncResult: SyncResult?
    public let failureMessage: String?
    public let startedAt: Date
    public let finishedAt: Date?

    public var isActive: Bool {
        switch state {
        case .created, .syncingLibrary, .reporting:
            true
        case .completed, .completedNoOp, .failed:
            false
        }
    }

    public init(
        runID: RunID,
        requestID: RunRequestID,
        trigger: RunTrigger,
        intent: RunIntent,
        state: RunLifecycleState,
        scope: ProcessingScopeSnapshot,
        syncResult: SyncResult?,
        failureMessage: String?,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.runID = runID
        self.requestID = requestID
        self.trigger = trigger
        self.intent = intent
        self.state = state
        self.scope = scope
        self.syncResult = syncResult
        self.failureMessage = failureMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public func replacing(
        state: RunLifecycleState,
        syncResult: SyncResult? = nil,
        failureMessage: String? = nil,
        finishedAt: Date? = nil
    ) -> Self {
        Self(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: intent,
            state: state,
            scope: scope,
            syncResult: syncResult ?? self.syncResult,
            failureMessage: failureMessage ?? self.failureMessage,
            startedAt: startedAt,
            finishedAt: finishedAt ?? self.finishedAt
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
