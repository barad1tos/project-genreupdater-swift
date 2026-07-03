import Foundation

public struct RunLifecycleTransition: Codable, Equatable, Sendable {
    public let state: RunLifecycleState
    public let timestamp: Date

    public init(state: RunLifecycleState, timestamp: Date) {
        self.state = state
        self.timestamp = timestamp
    }
}

public struct RunRecord: Identifiable, Codable, Equatable, Sendable {
    public let runID: RunID
    public let requestID: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let scope: ProcessingScopeSnapshot
    public let transitions: [RunLifecycleTransition]
    public let syncSummary: ActivitySyncSummary?
    public let failureMessage: String?
    public let startedAt: Date
    public let finishedAt: Date?

    public var id: RunID {
        runID
    }

    public var state: RunLifecycleState {
        transitions.last?.state ?? .created
    }

    public init(
        runID: RunID,
        requestID: RunRequestID,
        trigger: RunTrigger,
        intent: RunIntent,
        scope: ProcessingScopeSnapshot,
        transitions: [RunLifecycleTransition],
        syncSummary: ActivitySyncSummary?,
        failureMessage: String?,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.runID = runID
        self.requestID = requestID
        self.trigger = trigger
        self.intent = intent
        self.scope = scope
        self.transitions = transitions
        self.syncSummary = syncSummary
        self.failureMessage = failureMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public protocol RunRecordStore: Sendable {
    func upsert(_ record: RunRecord) async throws
    func loadAll() async throws -> [RunRecord]
    func record(for runID: RunID) async throws -> RunRecord?
}
