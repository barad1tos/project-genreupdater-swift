import Foundation

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
    public let skippedCorruptedCount: Int

    public init(records: [RunRecord], skippedCorruptedCount: Int) {
        self.records = records
        self.skippedCorruptedCount = skippedCorruptedCount
    }
}
