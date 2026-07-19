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
    public let configuration: RunConfig?
    public let writeTarget: FixPlanWriteTarget?
    public let recoveryID: UUID?
    public let transitions: [RunLifecycleTransition]
    public let workItems: [RunWorkItem]
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
        configuration: RunConfig? = nil,
        writeTarget: FixPlanWriteTarget? = nil,
        recoveryID: UUID? = nil,
        transitions: [RunLifecycleTransition],
        workItems: [RunWorkItem] = [],
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
        self.configuration = configuration
        self.writeTarget = writeTarget
        self.recoveryID = recoveryID
        self.transitions = transitions
        self.workItems = workItems
        self.syncSummary = syncSummary
        self.writeSummary = writeSummary
        self.failureMessage = failureMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public func closingRecovery(at finishedAt: Date) -> Self {
        var transitions = transitions
        let auditTime = max(finishedAt, transitions.last?.timestamp ?? startedAt)
        if state != .recovering {
            transitions.append(RunLifecycleTransition(state: .recovering, timestamp: auditTime))
        }
        transitions.append(RunLifecycleTransition(state: .cancelled, timestamp: auditTime))
        let closure = "Recovery closed after Music.app verification; interrupted writes were not resumed."
        let message = failureMessage.map { "\($0) \(closure)" } ?? closure
        return Self(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: intent,
            scope: scope,
            configuration: configuration,
            writeTarget: writeTarget,
            recoveryID: recoveryID,
            transitions: transitions,
            workItems: workItems,
            syncSummary: syncSummary,
            writeSummary: writeSummary,
            failureMessage: message,
            startedAt: startedAt,
            finishedAt: auditTime
        )
    }

    public func openingRecovery(id: UUID, at timestamp: Date) -> Self {
        var transitions = transitions
        let auditTime = max(timestamp, transitions.last?.timestamp ?? startedAt)
        if state != .recoverable, state != .blocked {
            transitions.append(RunLifecycleTransition(state: .recoverable, timestamp: auditTime))
        }
        return Self(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: intent,
            scope: scope,
            configuration: configuration,
            writeTarget: writeTarget,
            recoveryID: id,
            transitions: transitions,
            workItems: workItems,
            syncSummary: syncSummary,
            writeSummary: writeSummary,
            failureMessage: failureMessage ?? "Interrupted write requires Music.app verification.",
            startedAt: startedAt,
            finishedAt: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case runID, requestID, trigger, intent, scope, configuration, writeTarget, recoveryID
        case transitions, workItems, syncSummary, writeSummary, failureMessage, startedAt, finishedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(RunID.self, forKey: .runID)
        requestID = try container.decode(RunRequestID.self, forKey: .requestID)
        trigger = try container.decode(RunTrigger.self, forKey: .trigger)
        intent = try container.decode(RunIntent.self, forKey: .intent)
        scope = try container.decode(ProcessingScopeSnapshot.self, forKey: .scope)
        configuration = try container.decodeIfPresent(RunConfig.self, forKey: .configuration)
        writeTarget = try container.decodeIfPresent(FixPlanWriteTarget.self, forKey: .writeTarget)
        recoveryID = try container.decodeIfPresent(UUID.self, forKey: .recoveryID)
        transitions = try container.decode([RunLifecycleTransition].self, forKey: .transitions)
        workItems = if container.contains(.workItems) {
            try container.decode([RunWorkItem].self, forKey: .workItems)
        } else {
            []
        }
        syncSummary = try container.decodeIfPresent(ActivitySyncSummary.self, forKey: .syncSummary)
        writeSummary = try container.decodeIfPresent(RunWriteSummary.self, forKey: .writeSummary)
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
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
    /// evidence, not disposable history. Unreadable terminal rows are pruned
    /// only when their header and salvage route prove they are read-only;
    /// write or unsupported-schema evidence is retained. A `limit` below 1
    /// is a no-op. Returns the number of deleted rows.
    func prune(keepingLatest limit: Int) async throws -> Int

    /// Lists open recovery candidates plus corrupted terminal audits that need
    /// repair. Corrupted rows are returned by identifier for fail-closed handling.
    func recoveryRecords() async throws -> RunReportPage

    /// Opens recovery only while the persisted run is still an unfinished write.
    /// Returns an existing claim when recovery is already open, or `nil` when
    /// the run is missing, terminal, or not an unfinished write.
    func claimRecovery(for runID: RunID, id: UUID, at timestamp: Date) async throws -> UUID?

    /// Repairs a corrupted unfinished write or terminal write audit after Music.app verification.
    /// Returns false if the row is missing, healthy, unresolved-blocked, read-only, or from a future schema.
    func closeCorruptedRun(_ runID: RunID, at finishedAt: Date) async throws -> Bool

    /// Repairs corruption that does not represent an unfinished write, without touching Music.app.
    /// Returns false if unresolved write evidence exists or the payload uses a future schema.
    func closeReadOnlyCorruption(_ runID: RunID, at finishedAt: Date) async throws -> Bool

    /// Lists run history for report surfaces, newest first. Unlike `loadAll()`,
    /// corrupted rows are skipped, logged, and counted in the returned page so
    /// one bad row cannot make the whole history unreadable. Corrupted rows
    /// still consume `limit` slots of the fetch window, so a page can hold
    /// fewer than `limit` records while older valid rows exist beyond it;
    /// `skippedCorruptedCount` covers only the fetched window.
    func reports(matching query: RunReportQuery) async throws -> RunReportPage
}

extension RunRecordStore {
    public func closeReadOnlyCorruption(_: RunID, at _: Date) async throws -> Bool {
        false
    }
}
