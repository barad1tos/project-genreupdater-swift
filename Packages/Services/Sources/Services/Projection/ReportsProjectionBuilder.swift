import Foundation

public struct ReportsProjectionInput: Equatable, Sendable {
    public let records: [RunRecord]
    public let skippedCorruptedCount: Int
    public let now: Date

    public init(records: [RunRecord], skippedCorruptedCount: Int, now: Date) {
        self.records = records
        self.skippedCorruptedCount = skippedCorruptedCount
        self.now = now
    }
}

public enum ReportsProjectionBuilder {
    public static func makeProjection(from input: ReportsProjectionInput) -> ReportsProjection {
        ReportsProjection(
            revision: .initial,
            runs: input.records.map { makeRunItem(from: $0, now: input.now) },
            skippedCorruptedCount: input.skippedCorruptedCount
        )
    }

    private static func makeRunItem(from record: RunRecord, now: Date) -> ReportsRunItem {
        let state = ReportsRunLabels.runState(from: record.state)
        return ReportsRunItem(
            id: record.runID.rawValue.uuidString,
            state: state,
            stateLabel: ReportsRunLabels.stateLabel(for: state),
            triggerLabel: ReportsRunLabels.triggerLabel(for: record.trigger),
            startedLabel: ReportsRunLabels.relativeLabel(since: record.startedAt, now: now),
            durationLabel: ReportsRunLabels.durationLabel(startedAt: record.startedAt, finishedAt: record.finishedAt),
            changeCountLabel: ReportsRunLabels.changeCountLabel(for: record.syncSummary),
            failureSummary: ReportsRunLabels.failureSummary(state: state, failureMessage: record.failureMessage)
        )
    }
}
