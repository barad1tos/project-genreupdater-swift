import Foundation

public struct RunLifecycleTransition: Codable, Equatable, Sendable {
    public let state: RunLifecycleState
    public let timestamp: Date

    public init(state: RunLifecycleState, timestamp: Date) {
        self.state = state
        self.timestamp = timestamp
    }
}

public struct RunWriteSummary: Codable, Equatable, Sendable {
    public let applied: Int
    public let verifiedNoOp: Int
    public let failed: Int

    public init(applied: Int, verifiedNoOp: Int, failed: Int) {
        self.applied = applied
        self.verifiedNoOp = verifiedNoOp
        self.failed = failed
    }
}

public struct RunRecord: Identifiable, Codable, Equatable, Sendable {
    public let runID: RunID
    public let requestID: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let scope: ProcessingScopeSnapshot
    public let writeTarget: FixPlanWriteTarget?
    public let recoveryID: UUID?
    public let transitions: [RunLifecycleTransition]
    public let syncSummary: ActivitySyncSummary?
    public let writeSummary: RunWriteSummary?
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
        writeTarget: FixPlanWriteTarget? = nil,
        recoveryID: UUID? = nil,
        transitions: [RunLifecycleTransition],
        syncSummary: ActivitySyncSummary?,
        writeSummary: RunWriteSummary? = nil,
        failureMessage: String?,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.runID = runID
        self.requestID = requestID
        self.trigger = trigger
        self.intent = intent
        self.scope = scope
        self.writeTarget = writeTarget
        self.recoveryID = recoveryID
        self.transitions = transitions
        self.syncSummary = syncSummary
        self.writeSummary = writeSummary
        self.failureMessage = failureMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public func closingRecovery(at finishedAt: Date) -> Self {
        var transitions = transitions
        if state != .recovering {
            transitions.append(RunLifecycleTransition(state: .recovering, timestamp: finishedAt))
        }
        transitions.append(RunLifecycleTransition(state: .cancelled, timestamp: finishedAt))
        let closure = "Recovery closed after Music.app verification; interrupted writes were not resumed."
        let message = failureMessage.map { "\($0) \(closure)" } ?? closure
        return Self(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: intent,
            scope: scope,
            writeTarget: writeTarget,
            recoveryID: recoveryID,
            transitions: transitions,
            syncSummary: syncSummary,
            writeSummary: writeSummary,
            failureMessage: message,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    public func openingRecovery(id: UUID, at timestamp: Date) -> Self {
        var transitions = transitions
        if state != .recoverable, state != .blocked {
            transitions.append(RunLifecycleTransition(state: .recoverable, timestamp: timestamp))
        }
        return Self(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: intent,
            scope: scope,
            writeTarget: writeTarget,
            recoveryID: id,
            transitions: transitions,
            syncSummary: syncSummary,
            writeSummary: writeSummary,
            failureMessage: failureMessage ?? "Interrupted write requires Music.app verification.",
            startedAt: startedAt,
            finishedAt: nil
        )
    }
}

public protocol RunRecordStore: Sendable {
    func upsert(_ record: RunRecord) async throws

    /// Loads every persisted run record. All-or-nothing: a single corrupted row
    /// fails the whole load, deliberately; report surfaces that need per-row
    /// degradation use `reports(matching:)` instead.
    func loadAll() async throws -> [RunRecord]
    func record(for runID: RunID) async throws -> RunRecord?

    /// Deletes the oldest terminal records beyond `limit`. Open records
    /// (`finishedAt == nil`) are never pruned: unresolved runs are recovery
    /// evidence, not disposable history. A `limit` below 1 is a no-op so a
    /// misconfigured value cannot wipe the whole history. Returns the number
    /// of deleted rows.
    func prune(keepingLatest limit: Int) async throws -> Int

    /// Lists every unfinished write record without trusting its denormalized
    /// state field. Corrupted rows are returned by identifier for fail-closed
    /// recovery handling.
    func recoveryRecords() async throws -> RunReportPage

    /// Opens recovery only while the persisted run is still an unfinished write.
    /// Returns an existing claim when recovery is already open, or `nil` when
    /// the run is missing, terminal, or not an unfinished write.
    func claimRecovery(for runID: RunID, id: UUID, at timestamp: Date) async throws -> UUID?

    /// Marks one still-corrupted unfinished write terminal after Music.app
    /// verification. Returns false if the row is missing, terminal, or healthy.
    func closeCorruptedRun(_ runID: RunID, at finishedAt: Date) async throws -> Bool

    /// Lists run history for report surfaces, newest first. Unlike `loadAll()`,
    /// corrupted rows are skipped, logged, and counted in the returned page so
    /// one bad row cannot make the whole history unreadable. Corrupted rows
    /// still consume `limit` slots of the fetch window, so a page can hold
    /// fewer than `limit` records while older valid rows exist beyond it;
    /// `skippedCorruptedCount` covers only the fetched window.
    func reports(matching query: RunReportQuery) async throws -> RunReportPage
}
