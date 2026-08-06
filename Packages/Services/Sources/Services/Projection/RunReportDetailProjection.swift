import Foundation

public struct RunReportTransitionItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let stageLabel: String
    public let timeLabel: String

    public init(id: String, stageLabel: String, timeLabel: String) {
        self.id = id
        self.stageLabel = stageLabel
        self.timeLabel = timeLabel
    }
}

public struct RunReportSummaryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// One run work item rendered in the report detail — display data plus the
/// flags the recovery affordances key on.
public struct RunReportWorkItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let changeLabel: String
    public let stateLabel: String
    public let isOpen: Bool
    public let isWriteUncertain: Bool
    public let dismissedLabel: String?

    public init(
        id: UUID,
        changeLabel: String,
        stateLabel: String,
        isOpen: Bool,
        isWriteUncertain: Bool,
        dismissedLabel: String?
    ) {
        self.id = id
        self.changeLabel = changeLabel
        self.stateLabel = stateLabel
        self.isOpen = isOpen
        self.isWriteUncertain = isWriteUncertain
        self.dismissedLabel = dismissedLabel
    }
}

public struct RunReportDetailProjection: Equatable, Sendable {
    public let runID: String
    public let state: ReportsRunState
    public let stateLabel: String
    public let triggerLabel: String
    public let startedLabel: String
    public let durationLabel: String?
    public let scopeLines: [String]
    public let transitions: [RunReportTransitionItem]
    public let summaryItems: [RunReportSummaryItem]
    public let detailMessage: String?
    public let workItems: [RunReportWorkItem]
    /// Items beyond the display cap; rendered as a "+N more" caption.
    public let hiddenWorkItemCount: Int
    /// Every grouped-dismissal-eligible item (.prepared), including items
    /// beyond the display cap — the view must not re-derive this set.
    public let preparedItemIDs: [UUID]
    /// Closed write run with continuable work: "Apply remaining fixes".
    public let canApplyRemainingFixes: Bool
    /// Suspended recovery run (recoverable/recovering/blocked, not the
    /// active run) with open items: dismissal affordances.
    public let canDismissItems: Bool
    /// Lineage and write evidence ("Continues run …", "Continued by …",
    /// plan reference, write summary); empty for unlinked observation runs.
    public let lineageLines: [String]

    public init(
        runID: String,
        state: ReportsRunState,
        stateLabel: String,
        triggerLabel: String,
        startedLabel: String,
        durationLabel: String?,
        scopeLines: [String],
        transitions: [RunReportTransitionItem],
        summaryItems: [RunReportSummaryItem],
        detailMessage: String?,
        workItems: [RunReportWorkItem] = [],
        hiddenWorkItemCount: Int = 0,
        preparedItemIDs: [UUID] = [],
        canApplyRemainingFixes: Bool = false,
        canDismissItems: Bool = false,
        lineageLines: [String] = []
    ) {
        self.runID = runID
        self.state = state
        self.stateLabel = stateLabel
        self.triggerLabel = triggerLabel
        self.startedLabel = startedLabel
        self.durationLabel = durationLabel
        self.scopeLines = scopeLines
        self.transitions = transitions
        self.summaryItems = summaryItems
        self.detailMessage = detailMessage
        self.workItems = workItems
        self.hiddenWorkItemCount = hiddenWorkItemCount
        self.preparedItemIDs = preparedItemIDs
        self.canApplyRemainingFixes = canApplyRemainingFixes
        self.canDismissItems = canDismissItems
        self.lineageLines = lineageLines
    }
}
