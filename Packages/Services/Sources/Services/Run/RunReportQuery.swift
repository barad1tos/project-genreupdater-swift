import Foundation

public struct RunReportQuery: Equatable, Sendable {
    public let startedAfter: Date?
    public let startedBefore: Date?
    public let states: Set<RunLifecycleState>?
    public let trigger: RunTrigger?
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
