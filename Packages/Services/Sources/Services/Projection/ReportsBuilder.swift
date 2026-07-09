import Foundation

public struct ReportsProjectionInput: Equatable, Sendable {
    public let records: [RunRecord]
    public let skippedCorruptedCount: Int
    public let now: Date
    public let activeRunID: RunID?

    public init(records: [RunRecord], skippedCorruptedCount: Int, now: Date, activeRunID: RunID? = nil) {
        self.records = records
        self.skippedCorruptedCount = skippedCorruptedCount
        self.now = now
        self.activeRunID = activeRunID
    }
}

public enum ReportsBuilder {
    public static func makeProjection(from input: ReportsProjectionInput) -> ReportsProjection {
        ReportsProjection(
            revision: .initial,
            runs: input.records.map { makeRunItem(from: $0, now: input.now, activeRunID: input.activeRunID) },
            skippedCorruptedCount: input.skippedCorruptedCount
        )
    }

    private static func makeRunItem(from record: RunRecord, now: Date, activeRunID: RunID?) -> ReportsRunItem {
        let state = ReportsRunLabels.runState(from: record, activeRunID: activeRunID)
        return ReportsRunItem(
            id: record.runID.rawValue.uuidString,
            state: state,
            stateLabel: ReportsRunLabels.stateLabel(for: state),
            triggerLabel: ReportsRunLabels.triggerLabel(for: record.trigger),
            startedLabel: ReportsRunLabels.relativeLabel(since: record.startedAt, now: now),
            modeLabel: ReportsRunLabels.modeLabel(for: record.intent),
            scopeLabel: ReportsRunLabels.scopeLabel(for: record.scope),
            durationLabel: ReportsRunLabels.durationLabel(startedAt: record.startedAt, finishedAt: record.finishedAt),
            changeCountLabel: ReportsRunLabels.changeCountLabel(for: record.syncSummary, intent: record.intent),
            failureSummary: ReportsRunLabels.failureSummary(state: state, failureMessage: record.failureMessage)
        )
    }
}
