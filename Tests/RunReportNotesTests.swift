import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run report operational")
struct RunReportNotesTests {
    @Test("models operational notes for mixed run health")
    func modelsOperationalNotesForMixedRunHealth() {
        var unchangedGenre = UpdateRunReportFixtures.makePureRockFuryChange(changeType: .genreUpdate)
        unchangedGenre.oldGenre = "Rock"
        unchangedGenre.newGenre = "Rock"

        let report = UpdateRunReportFixtures.makeMixedRunHealthReport(
            completedEntries: [UpdateRunReportFixtures.makePureRockFuryYearChange(), unchangedGenre]
        )

        #expect(report.scannedTrackCount == 3)
        #expect(report.changedEntries.count == 1)
        #expect(report.skippedCount == 1)
        #expect(report.failures.count == 1)
        #expect(report.hasOperationalNotes)

        let noteTitles = report.operationalNotes.map(\.title)
        #expect(noteTitles.contains("Skipped"))
        #expect(noteTitles.contains("Needs Attention"))
    }

    @Test("plain text summary includes operational notes and detailed report sections")
    func plainTextSummaryIncludesOperationalNotesAndDetailedReportSections() {
        let report = UpdateRunReportFixtures.makeMixedRunHealthReport(
            completedEntries: [UpdateRunReportFixtures.makePureRockFuryYearChange()],
            displayMode: .detailed
        )

        let summary = report.plainTextSummary
        #expect(summary.contains("Run Health"))
        #expect(summary.contains("Needs Attention"))
        #expect(summary.contains("Skipped"))
        #expect(summary.contains("Change Breakdown"))
        #expect(summary.contains("Track Details"))
    }

    @Test("plain text summary includes pending verification operational note")
    func plainTextSummaryIncludesPendingVerificationOperationalNote() throws {
        let report = UpdateRunReport(
            result: BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: []),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: [],
            operationalContext: .init(pendingVerification: .init(total: 3, due: 1, problematic: 2))
        )

        let note = try #require(report.operationalNotes.first { $0.id == "pending-verification" })
        #expect(note.title == "Pending Verification")
        #expect(note.detail == "3 pending, 1 due, 2 problematic.")
        #expect(note.severity == .warning)
        #expect(report.plainTextSummary.contains("Pending Verification"))
        #expect(report.plainTextSummary.contains("3 pending"))
        #expect(report.plainTextSummary.contains("2 problematic"))
    }

    @Test("Pending verification summary includes skipped and verified counts")
    func pendingSummaryIncludesLifecycleCounts() {
        let summary = UpdateRunPendingVerificationSummary(
            total: 10,
            due: 3,
            problematic: 1,
            skippedByInterval: 7,
            verified: 2
        )
        let report = UpdateRunReport(
            result: nil,
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: [],
            operationalContext: UpdateRunOperationalContext(
                pendingVerification: summary
            )
        )

        #expect(report.pendingVerification?.skippedByInterval == 7)
        #expect(report.pendingVerification?.verified == 2)
        #expect(report.plainTextSummary.contains("10 pending"))
        #expect(report.plainTextSummary.contains("3 due"))
        #expect(report.plainTextSummary.contains("1 problematic"))
        #expect(report.plainTextSummary.contains("7 skipped"))
        #expect(report.plainTextSummary.contains("2 verified"))
    }

    @Test("Recovery summary appears in report and plain text")
    func recoverySummaryAppearsInReportAndPlainText() {
        let recovery = UpdateRunRecoverySummary(restoredCount: 5, skippedCount: 2, failedCount: 1)
        let report = UpdateRunReport(
            result: nil,
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: [],
            operationalContext: UpdateRunOperationalContext(
                recovery: recovery
            )
        )

        #expect(report.recovery?.restoredCount == 5)
        #expect(report.recovery?.skippedCount == 2)
        #expect(report.recovery?.failedCount == 1)
        #expect(report.plainTextSummary.contains("Recovery"))
        #expect(report.plainTextSummary.contains("Restored: 5"))
        #expect(report.plainTextSummary.contains("Skipped: 2"))
        #expect(report.plainTextSummary.contains("Failed: 1"))
    }

    @Test("Recovery summary is nil when restore result has no outcomes")
    func recoverySummaryIsNilForEmptyResult() {
        let emptyResult = BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
        #expect(UpdateRunRecoverySummary(result: emptyResult) == nil)
    }
}
