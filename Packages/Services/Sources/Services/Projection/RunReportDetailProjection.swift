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
    public let failureMessage: String?

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
        failureMessage: String?
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
        self.failureMessage = failureMessage
    }
}
