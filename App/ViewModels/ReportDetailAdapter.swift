import DesignUI
import Services

enum ReportDetailAdapter {
    static func makeSnapshot(from detail: RunReportDetailProjection) -> RunReportDetailSnapshot {
        RunReportDetailSnapshot(
            runID: detail.runID,
            stateLabel: detail.stateLabel,
            tone: RunHistoryAdapter.makeTone(from: detail.state),
            triggerLabel: detail.triggerLabel,
            startedLabel: detail.startedLabel,
            durationLabel: detail.durationLabel,
            scopeLines: detail.scopeLines,
            transitions: detail.transitions.map { transition in
                RunReportTransitionRow(
                    id: transition.id,
                    stageLabel: transition.stageLabel,
                    timeLabel: transition.timeLabel
                )
            },
            summaryItems: detail.summaryItems.map { item in
                RunReportSummaryRow(id: item.id, label: item.label, value: item.value)
            },
            detailMessage: detail.detailMessage,
            workItems: detail.workItems.map { item in
                RunReportWorkItemRow(
                    id: item.id.uuidString,
                    changeLabel: item.changeLabel,
                    stateLabel: item.stateLabel,
                    isOpen: item.isOpen,
                    isWriteUncertain: item.isWriteUncertain,
                    dismissedLabel: item.dismissedLabel
                )
            },
            canApplyRemainingFixes: detail.canApplyRemainingFixes,
            canDismissItems: detail.canDismissItems
        )
    }
}
