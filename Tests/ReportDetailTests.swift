import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ReportDetailAdapter")
struct ReportDetailTests {
    @Test("maps detail projection fields to snapshot")
    func mapsDetailProjectionToSnapshot() {
        let itemID = UUID()
        let projection = RunReportDetailProjection(
            runID: "run-1",
            state: .completed,
            stateLabel: "Completed",
            triggerLabel: "Manual check",
            startedLabel: "2m ago",
            durationLabel: "45s",
            scopeLines: ["Scope: Full library", "Known tracks: 1,234"],
            transitions: [
                RunReportTransitionItem(id: "transition-0", stageLabel: "Created", timeLabel: "3m ago"),
            ],
            summaryItems: [
                RunReportSummaryItem(id: "summary-total", label: "Total changes", value: "6"),
            ],
            detailMessage: nil,
            workItems: [
                RunReportWorkItem(
                    id: itemID,
                    changeLabel: "Genre: Rock → Metal — Track A",
                    stateLabel: "Failed",
                    isOpen: false,
                    isWriteUncertain: true,
                    dismissedLabel: nil
                ),
            ],
            hiddenWorkItemCount: 4,
            preparedItemIDs: [itemID],
            canApplyRemainingFixes: true,
            canDismissItems: false
        )

        let snapshot = ReportDetailAdapter.makeSnapshot(from: projection)

        #expect(snapshot.runID == "run-1")
        #expect(snapshot.stateLabel == "Completed")
        #expect(snapshot.tone == .success)
        #expect(snapshot.triggerLabel == "Manual check")
        #expect(snapshot.startedLabel == "2m ago")
        #expect(snapshot.durationLabel == "45s")
        #expect(snapshot.scopeLines == ["Scope: Full library", "Known tracks: 1,234"])
        #expect(snapshot.transitions.map(\.id) == ["transition-0"])
        #expect(snapshot.transitions.map(\.stageLabel) == ["Created"])
        #expect(snapshot.transitions.map(\.timeLabel) == ["3m ago"])
        #expect(snapshot.summaryItems.map(\.id) == ["summary-total"])
        #expect(snapshot.summaryItems.map(\.label) == ["Total changes"])
        #expect(snapshot.summaryItems.map(\.value) == ["6"])
        #expect(snapshot.detailMessage == nil)
        #expect(snapshot.workItems == [
            RunReportWorkItemRow(
                id: itemID.uuidString,
                changeLabel: "Genre: Rock → Metal — Track A",
                stateLabel: "Failed",
                isOpen: false,
                isWriteUncertain: true,
                dismissedLabel: nil
            ),
        ])
        #expect(snapshot.hiddenWorkItemCount == 4)
        #expect(snapshot.preparedItemIDs == [itemID.uuidString])
        #expect(snapshot.canApplyRemainingFixes)
        #expect(!snapshot.canDismissItems)
        #expect(snapshot.unavailableReason == nil)
    }

    @Test("failed detail maps to error tone")
    func failedDetailMapsErrorTone() {
        let projection = RunReportDetailProjection(
            runID: "run-2",
            state: .failed,
            stateLabel: "Failed",
            triggerLabel: "Background sync",
            startedLabel: "5m ago",
            durationLabel: "12s",
            scopeLines: [],
            transitions: [],
            summaryItems: [],
            detailMessage: "Music.app unavailable"
        )

        let snapshot = ReportDetailAdapter.makeSnapshot(from: projection)

        #expect(snapshot.tone == .error)
        #expect(snapshot.detailMessage == "Music.app unavailable")
        #expect(snapshot.unavailableReason == nil)
    }

    @Test("dismiss item command carries run, item, and reason")
    func dismissItemCommandShape() {
        let runID = UUID()
        let itemID = UUID()

        let command = ReportDetailAdapter.dismissItemCommand(
            runID: runID.uuidString,
            itemID: itemID.uuidString,
            reason: "Duplicate"
        )

        #expect(command?.kind == .dismissRecoveryItem)
        #expect(command?.recoveryDismissal == RecoveryDismissalTarget(
            runID: runID,
            itemIDs: [itemID],
            reason: "Duplicate"
        ))
    }

    @Test("malformed identifiers produce no dismissal command")
    func malformedIdentifiersProduceNoCommand() {
        #expect(ReportDetailAdapter.dismissItemCommand(
            runID: "not-a-uuid",
            itemID: UUID().uuidString,
            reason: "Duplicate"
        ) == nil)
        #expect(ReportDetailAdapter.dismissPreparedItemsCommand(
            runID: UUID().uuidString,
            itemIDs: [UUID().uuidString, "not-a-uuid"],
            reason: "Duplicate"
        ) == nil)
    }

    @Test("grouped dismissal carries all prepared items")
    func groupedDismissalCommandShape() {
        let runID = UUID()
        let itemIDs = [UUID(), UUID()]

        let command = ReportDetailAdapter.dismissPreparedItemsCommand(
            runID: runID.uuidString,
            itemIDs: itemIDs.map(\.uuidString),
            reason: "Handled manually"
        )

        #expect(command?.kind == .dismissRecoveryItems)
        #expect(command?.recoveryDismissal == RecoveryDismissalTarget(
            runID: runID,
            itemIDs: itemIDs,
            reason: "Handled manually"
        ))
    }

    @Test("empty prepared selection produces no command")
    func emptyPreparedSelectionProducesNoCommand() {
        #expect(ReportDetailAdapter.dismissPreparedItemsCommand(
            runID: UUID().uuidString,
            itemIDs: [],
            reason: "Not wanted"
        ) == nil)
    }
}
