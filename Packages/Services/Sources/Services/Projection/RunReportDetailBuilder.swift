import Core
import Foundation

public enum RunReportDetailBuilder {
    private static let shownArtistLimit = 3
    /// Full-library write ledgers can hold thousands of items; the card
    /// renders a bounded window and reports the remainder as a count.
    static let shownWorkItemLimit = 100

    public static func makeDetail(
        from record: RunRecord,
        now: Date,
        activeRunID: RunID? = nil,
        continuedBy: [RunID] = []
    ) -> RunReportDetailProjection {
        let state = ReportsRunLabels.runState(from: record, activeRunID: activeRunID)
        let visibleWorkItems = makeVisibleWorkItems(from: record.workItems)
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
            detailMessage: ReportsRunLabels.detailMessage(state: state, failureMessage: record.failureMessage),
            workItems: visibleWorkItems.map(makeWorkItem),
            hiddenWorkItemCount: max(0, record.workItems.count - visibleWorkItems.count),
            preparedItemIDs: record.workItems.filter { $0.state == .prepared }.map(\.id),
            // writeTarget != nil: RunRequest.continuation fails closed on an
            // unverifiable source plan, so the affordance must hide with it.
            canApplyRemainingFixes: record.finishedAt != nil
                && record.intent == .writeFixes
                && record.writeTarget != nil
                && !record.continuableWork.isEmpty,
            // Strictly narrower than requireRecoveryResolution: the domain
            // gate alone admits states a dismissal command still rejects
            // downstream (closed records, the active run), so the card also
            // requires an open, non-active run with an actionable item.
            canDismissItems: record.finishedAt == nil
                && record.state.isResolvingRecovery
                && record.runID != activeRunID
                && record.workItems.contains(where: canDismissItem),
            lineageLines: makeLineageLines(from: record, continuedBy: continuedBy)
        )
    }

    private static func makeLineageLines(from record: RunRecord, continuedBy: [RunID]) -> [String] {
        var lines: [String] = []
        if let source = record.continuesRunID {
            lines.append("Continues run \(ReportsRunLabels.shortRunID(source))")
        }
        if !continuedBy.isEmpty {
            let list = continuedBy.map(ReportsRunLabels.shortRunID).joined(separator: ", ")
            lines.append("Continued by \(list)")
        }
        if let target = record.writeTarget {
            let planID = target.planID.rawValue.uuidString.prefix(8)
            lines.append(
                "Plan \(planID) · rev \(target.planRevision.value).\(target.decisionRevision.value)"
            )
        }
        if let summary = record.writeSummary {
            lines.append(
                "Writes: \(summary.applied) applied · \(summary.verifiedNoOp) no-op · \(summary.failed) failed"
            )
        }
        return lines
    }

    private static func makeWorkItem(from item: RunWorkItem) -> RunReportWorkItem {
        RunReportWorkItem(
            id: item.id,
            changeLabel: makeChangeLabel(from: item),
            stateLabel: makeItemStateLabel(for: item.state),
            isOpen: isOpenItem(item),
            isWriteUncertain: item.state.isWriteUncertain,
            canDismiss: canDismissItem(item),
            attentionLabel: item.recoveryObservationIssue?.userGuidance,
            dismissedLabel: item.dismissedAt == nil ? nil : item.detail
        )
    }

    private static func makeVisibleWorkItems(from items: [RunWorkItem]) -> [RunWorkItem] {
        let boundedItems = Array(items.prefix(shownWorkItemLimit))
        let boundedIDs = Set(boundedItems.map(\.id))
        let additionalBlockers = items.filter {
            !boundedIDs.contains($0.id) && $0.isRecoveryAcknowledgementRequired
        }
        return boundedItems + additionalBlockers
    }

    private static func isOpenItem(_ item: RunWorkItem) -> Bool {
        if case .outcome = item.state {
            return false
        }
        return true
    }

    private static func canDismissItem(_ item: RunWorkItem) -> Bool {
        isOpenItem(item) || item.isRecoveryAcknowledgementRequired
    }

    private static func makeChangeLabel(from item: RunWorkItem) -> String {
        let subject = switch item.target {
        case let .track(identity): identity.trackName
        case let .album(identity): identity.album
        }
        let change = item.effectiveChange
        let values = ChangeDisplay.values(
            oldValue: change.oldValue,
            newValue: change.newValue,
            albumArtistChange: change.albumArtistChange
        )
        let transition = "\(values.oldValue ?? "—") → \(values.newValue ?? "—")"
        return "\(makeChangeTypeLabel(for: change.changeType)): \(transition) — \(subject)"
    }

    private static func makeChangeTypeLabel(for changeType: ChangeType) -> String {
        switch changeType {
        case .genreUpdate: "Genre"
        case .yearUpdate: "Year"
        case .yearRevert: "Year revert"
        case .trackCleaning: "Track name"
        case .albumCleaning: "Album name"
        case .artistRename: "Artist"
        }
    }

    private static func makeItemStateLabel(for state: WorkState) -> String {
        switch state {
        case .prepared: "Prepared"
        case .attempting: "Attempting"
        case .attempted: "Attempted"
        case let .outcome(outcome): makeOutcomeLabel(for: outcome)
        }
    }

    private static func makeOutcomeLabel(for outcome: WorkOutcome) -> String {
        switch outcome {
        case .written: "Written"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .dismissed: "Dismissed"
        case .needsReview: "Needs review"
        case .deferred: "Deferred"
        case .noFixNeeded: "No fix needed"
        case .fixProposed: "Fix proposed"
        }
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
