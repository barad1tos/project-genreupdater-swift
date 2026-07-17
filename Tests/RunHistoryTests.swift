import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("RunHistoryAdapter")
struct RunHistoryTests {
    @Test("maps every unresolved run into recovery projection")
    func mapsUnresolvedRuns() {
        let recoveryRunID = RunID()
        let attentionRunID = RunID()
        let unsupportedRunID = RunID()
        let page = RunReportPage(
            records: [],
            skippedCorruptedCount: 3,
            recoveryRunIDs: [recoveryRunID],
            attentionRunIDs: [attentionRunID],
            unsupportedRunIDs: [unsupportedRunID]
        )

        let input = RunHistoryAdapter.makeInput(from: page, now: Date(), activeRunID: nil)
        let projection = ReportsBuilder.makeProjection(from: input)

        #expect(input.recoveryRunIDs == [recoveryRunID, attentionRunID, unsupportedRunID])
        #expect(projection.recoveryRunIDs == [
            recoveryRunID.rawValue.uuidString,
            attentionRunID.rawValue.uuidString,
            unsupportedRunID.rawValue.uuidString,
        ])
    }

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
