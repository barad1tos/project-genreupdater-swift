import Foundation

public struct ReportsProjectionInput: Equatable, Sendable {
    public let records: [RunRecord]
    public let skippedCorruptedCount: Int
    public let recoveryRunIDs: [RunID]
    public let now: Date
    public let activeRunID: RunID?

    public init(
        records: [RunRecord],
        skippedCorruptedCount: Int,
        recoveryRunIDs: [RunID] = [],
        now: Date,
        activeRunID: RunID? = nil
    ) {
        self.records = records
        self.skippedCorruptedCount = skippedCorruptedCount
        self.recoveryRunIDs = recoveryRunIDs
        self.now = now
        self.activeRunID = activeRunID
    }
}

public enum ReportsBuilder {
    public static func makeProjection(from input: ReportsProjectionInput) -> ReportsProjection {
        var seenRecoveryIDs = Set<String>()
        let recoveryRunIDs = (input.records.compactMap { record -> String? in
            guard record.finishedAt == nil,
                  record.intent == .writeFixes,
                  record.state.needsWriteRecovery,
                  record.runID != input.activeRunID
            else { return nil }
            return record.runID.rawValue.uuidString
        } + input.recoveryRunIDs.compactMap { runID in
            runID == input.activeRunID ? nil : runID.rawValue.uuidString
        }).filter {
            seenRecoveryIDs.insert($0).inserted
        }

        return ReportsProjection(
            revision: .initial,
            runs: input.records.map { makeRunItem(from: $0, now: input.now, activeRunID: input.activeRunID) },
            skippedCorruptedCount: input.skippedCorruptedCount,
            recoveryRunIDs: recoveryRunIDs
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
