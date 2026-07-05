import DesignUI
import Testing

@Suite("RunReportDetailSnapshot")
struct RunReportDetailSnapshotTests {
    @Test("unavailable snapshot carries reason and run id")
    func unavailableSnapshotCarriesReasonAndRunID() {
        let snapshot = RunReportDetailSnapshot.unavailable(runID: "run-1")

        #expect(snapshot.runID == "run-1")
        #expect(snapshot.unavailableReason == "This run report is no longer available")
        #expect(snapshot.stateLabel.isEmpty)
        #expect(snapshot.tone == .neutral)
        #expect(snapshot.scopeLines.isEmpty)
        #expect(snapshot.transitions.isEmpty)
        #expect(snapshot.summaryItems.isEmpty)
    }
}
