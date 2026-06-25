import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run failure reporting")
struct UpdateRunFailureTests {
    @Test("keeps repeated write failures for one track")
    func keepsRepeatedWriteFailuresForOneTrack() {
        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                failedTrackIDs: ["track-1", "track-1"],
                errorDescriptions: [
                    "Failed to write genre",
                    "Failed to write year",
                ]
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [
                Track(
                    id: "track-1",
                    name: "Song",
                    artist: "Artist",
                    album: "Album"
                ),
            ],
            testArtists: []
        )

        #expect(report.title == "Finished with 2 issues")
        #expect(report.failures.map { failure in failure.message } == [
            "Failed to write genre",
            "Failed to write year",
        ])
        #expect(Set(report.failures.map { failure in failure.id }).count == 2)
        #expect(report.failures.allSatisfy { failure in failure.technicalID == "track-1" })
        let failureBreakdowns = report.outcomeBreakdown.filter { breakdown in
            breakdown.outcome == UpdateRunOutcome.failed
        }
        #expect(failureBreakdowns.map { breakdown in breakdown.count }.reduce(0, +) == 2)
        #expect(failureBreakdowns.allSatisfy { breakdown in breakdown.trackCount == 1 })
    }
}
