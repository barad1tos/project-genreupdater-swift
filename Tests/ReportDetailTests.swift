import DesignUI
import Services
import Testing
@testable import Genre_Updater

@Suite("ReportDetailAdapter")
struct ReportDetailTests {
    @Test("maps detail projection fields to snapshot")
    func mapsDetailProjectionToSnapshot() {
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
            detailMessage: nil
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
}
