import DesignUI
import Services
import Testing
@testable import Genre_Updater

@Suite("RunHistoryAdapter")
struct RunHistoryTests {
    @Test("maps run item fields to row")
    func mapsRunItemFieldsToRow() throws {
        let item = ReportsRunItem(
            id: "run-1",
            state: .completed,
            stateLabel: "Completed",
            triggerLabel: "Manual check",
            startedLabel: "2m ago",
            modeLabel: "Preview",
            scopeLabel: "Test artists (2)",
            durationLabel: "45s",
            changeCountLabel: "12 changes",
            failureSummary: nil
        )
        let projection = ReportsProjection(revision: .initial, runs: [item], skippedCorruptedCount: 0)

        let row = try #require(RunHistoryAdapter.makeRunHistory(from: projection).first)

        #expect(row.id == "run-1")
        #expect(row.stateLabel == "Completed")
        #expect(row.tone == .success)
        #expect(row.triggerLabel == "Manual check")
        #expect(row.startedLabel == "2m ago")
        #expect(row.modeLabel == "Preview")
        #expect(row.scopeLabel == "Test artists (2)")
        #expect(row.durationLabel == "45s")
        #expect(row.changeCountLabel == "12 changes")
        #expect(row.failureSummary == nil)
    }

    @Test(
        "tone per run state",
        arguments: zip(
            [
                ReportsRunState.running,
                .awaitingReview,
                .completed,
                .completedNoOp,
                .blocked,
                .failed,
                .cancelled,
                .recoveryNeeded
            ],
            [Tone.info, .warning, .success, .neutral, .warning, .error, .neutral, .warning]
        )
    )
    func tonePerRunState(state: ReportsRunState, expectedTone: Tone) {
        #expect(RunHistoryAdapter.makeTone(from: state) == expectedTone)
    }
}
