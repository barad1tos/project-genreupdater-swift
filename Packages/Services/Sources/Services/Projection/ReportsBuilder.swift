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
                  record.intent.isMutating,
                  record.state.needsWriteRecovery,
                  record.runID != input.activeRunID
            else { return nil }
            return record.runID.rawValue.uuidString
        } + input.recoveryRunIDs.compactMap { runID in
            runID == input.activeRunID ? nil : runID.rawValue.uuidString
        }).filter {
            seenRecoveryIDs.insert($0).inserted
        }

        // In-page lineage edges only: `continuesRunID` travels on the records
        // themselves, so markers need no store call; a source outside the
        // fetched page still gets its "Continues …" text, just without an
        // in-page counterpart row.
        var continuedBy: [RunID: [RunID]] = [:]
        for record in input.records {
            if let source = record.continuesRunID {
                continuedBy[source, default: []].append(record.runID)
            }
        }

        return ReportsProjection(
            revision: .initial,
            runs: input.records.map { record in
                makeRunItem(
                    from: record,
                    now: input.now,
                    activeRunID: input.activeRunID,
                    continuedBy: continuedBy[record.runID] ?? []
                )
            },
            skippedCorruptedCount: input.skippedCorruptedCount,
            recoveryRunIDs: recoveryRunIDs
        )
    }

    private static func makeRunItem(
        from record: RunRecord,
        now: Date,
        activeRunID: RunID?,
        continuedBy: [RunID]
    ) -> ReportsRunItem {
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
            failureSummary: ReportsRunLabels.failureSummary(state: state, failureMessage: record.failureMessage),
            lineageLabel: makeLineageLabel(from: record, continuedBy: continuedBy)
        )
    }

    private static func makeLineageLabel(from record: RunRecord, continuedBy: [RunID]) -> String? {
        var parts: [String] = []
        if let source = record.continuesRunID {
            parts.append("Continues \(ReportsRunLabels.shortRunID(source))")
        }
        if !continuedBy.isEmpty {
            let list = continuedBy.map(ReportsRunLabels.shortRunID).joined(separator: ", ")
            parts.append("Continued by \(list)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
