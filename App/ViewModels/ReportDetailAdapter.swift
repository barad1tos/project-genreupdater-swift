import DesignUI
import Foundation
import Services

enum ReportDetailAdapter {
    static func dismissItemCommand(runID: String, itemID: String, reason: String) -> UserIntentCommand? {
        guard let runUUID = UUID(uuidString: runID), let itemUUID = UUID(uuidString: itemID) else {
            return nil
        }
        return .dismissRecoveryItem(runID: runUUID, itemID: itemUUID, reason: reason)
    }

    static func dismissPreparedItemsCommand(runID: String, itemIDs: [String], reason: String) -> UserIntentCommand? {
        let itemUUIDs = itemIDs.compactMap(UUID.init(uuidString:))
        guard let runUUID = UUID(uuidString: runID),
              !itemUUIDs.isEmpty,
              itemUUIDs.count == itemIDs.count
        else { return nil }
        return .dismissRecoveryItems(runID: runUUID, itemIDs: itemUUIDs, reason: reason)
    }

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
            hiddenWorkItemCount: detail.hiddenWorkItemCount,
            preparedItemIDs: detail.preparedItemIDs.map(\.uuidString),
            canApplyRemainingFixes: detail.canApplyRemainingFixes,
            canDismissItems: detail.canDismissItems
        )
    }
}
