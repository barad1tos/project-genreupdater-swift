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
    /// store-wide total. Skipped rows still consume `limit` slots.
    public let skippedCorruptedCount: Int
    /// Identifiers for every corrupted row counted in this fetched window.
    public let corruptedRunIDs: [RunID]
    /// Corrupted unfinished rows that may represent interrupted writes.
    public let recoveryRunIDs: [RunID]

    public init(
        records: [RunRecord],
        skippedCorruptedCount: Int,
        corruptedRunIDs: [RunID] = [],
        recoveryRunIDs: [RunID] = []
    ) {
        self.records = records
        self.skippedCorruptedCount = skippedCorruptedCount
        self.corruptedRunIDs = corruptedRunIDs
        self.recoveryRunIDs = recoveryRunIDs
    }
}
