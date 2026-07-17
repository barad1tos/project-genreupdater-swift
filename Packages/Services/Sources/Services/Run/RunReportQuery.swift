import Foundation

/// Filter set for run-history report reads. All filters are optional and
/// combine with logical AND; an inverted date range (`startedAfter` later
/// than `startedBefore`) matches nothing.
public struct RunReportQuery: Equatable, Sendable {
    /// Inclusive lower bound on `startedAt` (`>=`).
    public let startedAfter: Date?
    /// Inclusive upper bound on `startedAt` (`<=`).
    public let startedBefore: Date?
    /// Filter on the run's final/current state; nil or empty means all states.
    public let states: Set<RunLifecycleState>?
    /// Filter on the trigger source; nil means all triggers.
    public let trigger: RunTrigger?
    /// Fetch-window size; nil or values below 1 mean unlimited.
    public let limit: Int?

    public init(
        startedAfter: Date? = nil,
        startedBefore: Date? = nil,
        states: Set<RunLifecycleState>? = nil,
        trigger: RunTrigger? = nil,
        limit: Int? = nil
    ) {
        self.startedAfter = startedAfter
        self.startedBefore = startedBefore
        self.states = states
        self.trigger = trigger
        self.limit = limit
    }
}

public struct RunReportPage: Equatable, Sendable {
    public let records: [RunRecord]
    /// Corrupted rows skipped within the fetched window only — not a
    /// store-wide total. Recovery discovery also counts corrupted read-only
    /// rows scanned for closure even though healthy read-only rows are omitted.
    public let skippedCorruptedCount: Int
    /// Identifiers for every row included in `skippedCorruptedCount`.
    public let corruptedRunIDs: [RunID]
    /// Corrupted rows that may represent unresolved or unauditable writes.
    public let recoveryRunIDs: [RunID]
    /// Corrupted rows repairable without write recovery, including finished terminal audits.
    public let closableRunIDs: [RunID]
    /// Corrupted rows that require an explicit decision or safer app-side repair.
    public let attentionRunIDs: [RunID]
    /// Corrupted rows written by a newer payload schema and requiring an app update.
    public let unsupportedRunIDs: [RunID]

    /// Every corrupted run that blocks safe writes or needs an explicit recovery decision.
    public var unresolvedRunIDs: [RunID] {
        var seen = Set<RunID>()
        return (recoveryRunIDs + attentionRunIDs + unsupportedRunIDs).filter {
            seen.insert($0).inserted
        }
    }

    public init(
        records: [RunRecord],
        skippedCorruptedCount: Int,
        corruptedRunIDs: [RunID] = [],
        recoveryRunIDs: [RunID] = [],
        closableRunIDs: [RunID] = [],
        attentionRunIDs: [RunID] = [],
        unsupportedRunIDs: [RunID] = []
    ) {
        self.records = records
        self.skippedCorruptedCount = skippedCorruptedCount
        self.corruptedRunIDs = corruptedRunIDs
        self.recoveryRunIDs = recoveryRunIDs
        self.closableRunIDs = closableRunIDs
        self.attentionRunIDs = attentionRunIDs
        self.unsupportedRunIDs = unsupportedRunIDs
    }
}
