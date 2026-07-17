import Foundation

public enum RunReportDetailBuilder {
    private static let shownArtistLimit = 3

    public static func makeDetail(
        from record: RunRecord,
        now: Date,
        activeRunID: RunID? = nil
    ) -> RunReportDetailProjection {
        let state = ReportsRunLabels.runState(from: record, activeRunID: activeRunID)
        return RunReportDetailProjection(
            runID: record.runID.rawValue.uuidString,
            state: state,
            stateLabel: ReportsRunLabels.stateLabel(for: state),
            triggerLabel: ReportsRunLabels.triggerLabel(for: record.trigger),
            startedLabel: ReportsRunLabels.relativeLabel(since: record.startedAt, now: now),
            durationLabel: ReportsRunLabels.durationLabel(startedAt: record.startedAt, finishedAt: record.finishedAt),
            scopeLines: makeScopeLines(from: record.scope),
            transitions: makeTransitions(from: record.transitions, now: now),
            summaryItems: makeSummaryItems(from: record.syncSummary, intent: record.intent),
            detailMessage: ReportsRunLabels.detailMessage(state: state, failureMessage: record.failureMessage)
        )
    }

    private static func makeScopeLines(from scope: ProcessingScopeSnapshot) -> [String] {
        var lines: [String] = []
        lines.append("Scope: \(ReportsRunLabels.scopeSourceLabel(for: scope))")
        switch scope.source {
        case .fullLibrary:
            if let knownTrackCount = scope.knownTrackCount {
                lines.append("Known tracks: \(knownTrackCount.formatted())")
            }
        case .testArtists:
            lines.append(makeArtistLine(from: scope.normalizedTestArtists))
        }
        // scope.reason is not rendered: production records carry the raw trigger
        // value there, which would duplicate triggerLabel as an unpolished string.
        return lines
    }

    private static func makeArtistLine(from artists: [String]) -> String {
        let displayedArtists = artists.prefix(shownArtistLimit).joined(separator: ", ")
        let hiddenCount = artists.count - shownArtistLimit
        return hiddenCount > 0
            ? "Artists: \(displayedArtists) +\(hiddenCount) more"
            : "Artists: \(displayedArtists)"
    }

    private static func makeTransitions(
        from transitions: [RunLifecycleTransition],
        now: Date
    ) -> [RunReportTransitionItem] {
        transitions.enumerated().map { index, transition in
            RunReportTransitionItem(
                id: "transition-\(index)",
                stageLabel: ReportsRunLabels.stageLabel(for: transition.state),
                timeLabel: ReportsRunLabels.relativeLabel(since: transition.timestamp, now: now)
            )
        }
    }

    private static func makeSummaryItems(
        from summary: ActivitySyncSummary?,
        intent: RunIntent
    ) -> [RunReportSummaryItem] {
        guard ReportsRunLabels.showsSyncSummary(for: intent) else { return [] }
        guard let summary else { return [] }
        return [
            RunReportSummaryItem(id: "summary-new", label: "New", value: summary.new.formatted()),
            RunReportSummaryItem(id: "summary-modified", label: "Modified", value: summary.modified.formatted()),
            RunReportSummaryItem(
                id: "summary-identity-changed",
                label: "Identity changed",
                value: summary.identityChanged.formatted()
            ),
            RunReportSummaryItem(id: "summary-refreshed", label: "Refreshed", value: summary.refreshed.formatted()),
            RunReportSummaryItem(id: "summary-removed", label: "Removed", value: summary.removed.formatted()),
            RunReportSummaryItem(id: "summary-total", label: "Total changes", value: summary.changeCount.formatted())
        ]
    }
}
