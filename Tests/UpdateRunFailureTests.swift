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

    @Test("keeps shared status failure detail when result descriptions are shorter")
    func keepsSharedStatusFailureDetailWhenResultDescriptionsAreShorter() {
        let tracks = [
            Track(id: "track-1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "track-2", name: "Two", artist: "Artist", album: "Album"),
        ]
        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                failedTrackIDs: ["track-1", "track-2"],
                errorDescriptions: ["Shared failure"]
            ),
            completedEntries: [],
            trackStatuses: [
                "track-1": .failed("Shared failure"),
                "track-2": .failed("Shared failure"),
            ],
            tracks: tracks,
            testArtists: []
        )

        #expect(report.failures.map { failure in failure.message } == ["Shared failure", "Shared failure"])
        #expect(!report.plainTextSummary.contains("No failure details were captured"))
        let failureBreakdowns = report.outcomeBreakdown.filter { breakdown in
            breakdown.outcome == UpdateRunOutcome.failed
        }
        #expect(failureBreakdowns.count == 1)
        #expect(failureBreakdowns.first?.count == 2)
        #expect(failureBreakdowns.first?.trackCount == 2)
    }

    @Test("keeps unknown-track failures reachable from album results")
    func keepsUnknownTrackFailuresReachableFromAlbumResults() throws {
        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                failedTrackIDs: ["raw-id"],
                errorDescriptions: ["Missing AppleScript ID"]
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: []
        )

        let album = try #require(report.albumResults.first)
        let failureRow = try #require(album.tracks.first)
        #expect(report.failures.count == 1)
        #expect(report.affectedAlbumCount == 1)
        #expect(album.artist == "Unknown artist")
        #expect(album.album == "Unknown album")
        #expect(failureRow.title == "Unknown track")
        #expect(failureRow.failureMessage == "Missing AppleScript ID")
    }

    @Test("keeps no-op-only albums in report results")
    func keepsNoOpOnlyAlbumsInReportResults() throws {
        var noOpEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "noop-track",
            artist: "In Flames",
            trackName: "Only for the Weak",
            albumName: "Clayman"
        )
        noOpEntry.oldYear = 2020
        noOpEntry.newYear = 2020

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                noOpEntries: [noOpEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: ["noop-track": .done],
            tracks: [
                Track(
                    id: "noop-track",
                    name: "Only for the Weak",
                    artist: "In Flames",
                    album: "Clayman",
                    year: 2020
                ),
            ],
            testArtists: []
        )

        let album = try #require(report.albumResults.first)
        #expect(report.changedTrackCount == 0)
        #expect(report.affectedAlbumCount == 1)
        #expect(report.affectedArtistCount == 1)
        #expect(album.trackCount == 1)
        #expect(album.changedTrackCount == 0)
        #expect(report.outcomeBreakdown.contains { breakdown in
            breakdown.outcome == UpdateRunOutcome.noChange
                && breakdown.operation == "Year"
                && breakdown.albumCount == 1
        })
    }
}
