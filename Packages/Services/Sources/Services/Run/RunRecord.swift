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

    /// Loads every persisted run record. All-or-nothing: a single corrupted row
    /// fails the whole load, deliberately, until a read consumer defines a
    /// per-row degradation policy.
    func loadAll() async throws -> [RunRecord]
    func record(for runID: RunID) async throws -> RunRecord?

    /// Deletes the oldest terminal records beyond `limit`. Open records
    /// (`finishedAt == nil`) are never pruned: unresolved runs are recovery
    /// evidence, not disposable history. Returns the number of deleted rows.
    func prune(keepingLatest limit: Int) async throws -> Int

    /// Lists run history for report surfaces, newest first. Unlike `loadAll()`,
    /// corrupted rows are skipped, logged, and counted in the returned page so
    /// one bad row cannot make the whole history unreadable.
    func reports(matching query: RunReportQuery) async throws -> RunReportPage
}
