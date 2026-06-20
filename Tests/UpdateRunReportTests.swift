import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run report")
struct UpdateRunReportTests {
    @Test("groups successful year changes by artist, album, and value")
    func groupsSuccessfulYearChangesByArtistAlbumAndValue() {
        let foregoneEntries = makeEntries(
            album: "Foregone",
            count: 13,
            oldYear: 2021,
            newYear: 2023
        )
        let subterraneanEntries = makeEntries(
            album: "Subterranean",
            count: 7,
            oldYear: 1995,
            newYear: 1994
        )
        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: foregoneEntries + subterraneanEntries,
                failedTrackIDs: ["failed-track"],
                errorDescriptions: ["Failed to write year"]
            ),
            completedEntries: [],
            trackStatuses: [
                "failed-track": .failed("Failed to write year"),
            ],
            tracks: [
                Track(
                    id: "failed-track",
                    name: "Failed Song",
                    artist: "In Flames",
                    album: "Foregone"
                ),
            ],
            testArtists: [" In Flames "]
        )

        #expect(report.title == "Finished with 1 issue")
        #expect(report.scopeTitle == "Test Artist: In Flames")
        #expect(report.changedTrackCount == 20)
        #expect(report.affectedAlbumCount == 2)
        #expect(report.affectedArtistCount == 1)

        let foregone = report.albumGroups.first { $0.album == "Foregone" }
        #expect(foregone?.changedTrackCount == 13)
        #expect(foregone?.changeSummary == "2021 -> 2023")
        let foregoneResult = report.albumResults.first { $0.album == "Foregone" }
        #expect(foregoneResult?.changedTrackCount == 13)
        #expect(foregoneResult?.failureCount == 1)
        #expect(foregoneResult?.trackCount == 14)

        let subterranean = report.albumGroups.first { $0.album == "Subterranean" }
        #expect(subterranean?.changedTrackCount == 7)
        #expect(subterranean?.changeSummary == "1995 -> 1994")

        #expect(report.failures.first?.title == "Failed Song")
        #expect(report.failures.first?.subtitle == "In Flames - Foregone")
        #expect(report.failures.first?.message == "Failed to write year")
        #expect(report.failures.first?.technicalID == "failed-track")
    }

    @Test("keeps unknown failures visible with technical fallback")
    func keepsUnknownFailuresVisibleWithTechnicalFallback() {
        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                failedTrackIDs: ["raw-id"],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: []
        )

        #expect(report.failures.count == 1)
        #expect(report.failures.first?.title == "Unknown track")
        #expect(report.failures.first?.subtitle == "Track ID: raw-id")
        #expect(report.failures.first?.message == "No failure details were captured for this run.")
        #expect(report.failures.first?.hasKnownTrack == false)
        #expect(report.albumResults.first?.artist == "Unknown artist")
        #expect(report.albumResults.first?.album == "Unknown album")
        #expect(report.albumResults.first?.failureCount == 1)
    }

    @Test("changed year rows show original editable year instead of release metadata")
    func changedYearRowsShowOriginalEditableYearInsteadOfReleaseMetadata() throws {
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "pure-rock-1",
            artist: "Clutch",
            trackName: "American Sleep",
            albumName: "Pure Rock Fury"
        )
        entry.oldYear = 1999
        entry.newYear = 2001

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [entry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: ["pure-rock-1": .done],
            tracks: [
                Track(
                    id: "pure-rock-1",
                    name: "American Sleep",
                    artist: "Clutch",
                    album: "Pure Rock Fury",
                    year: nil,
                    releaseYear: 2001
                ),
            ],
            testArtists: ["Clutch"]
        )

        guard let trackResult = report.albumResults.first?.tracks.first else {
            Issue.record("expected changed track row")
            return
        }
        #expect(trackResult.currentMetadataSummary == "Year 1999")
        #expect(trackResult.proposedSummary == "1999 -> 2001")
    }

    @Test("falls back to completed entries when batch result is unavailable")
    func fallsBackToCompletedEntriesWhenBatchResultIsUnavailable() {
        let report = UpdateRunReport(
            result: nil,
            completedEntries: makeEntries(
                album: "Foregone",
                count: 1,
                oldYear: 2021,
                newYear: 2023
            ),
            trackStatuses: ["foregone-1": .done, "skipped": .skipped],
            tracks: [],
            testArtists: []
        )

        #expect(report.title == "Update Complete")
        #expect(report.changedTrackCount == 1)
        #expect(report.skippedCount == 1)
        #expect(report.scannedTrackCount == 2)
    }

    private func makeEntries(
        album: String,
        count: Int,
        oldYear: Int,
        newYear: Int
    ) -> [ChangeLogEntry] {
        (1 ... count).map { index in
            var entry = ChangeLogEntry(
                changeType: .yearUpdate,
                trackID: "\(album)-\(index)",
                artist: "In Flames",
                trackName: "\(album) Track \(index)",
                albumName: album
            )
            entry.oldYear = oldYear
            entry.newYear = newYear
            return entry
        }
    }
}
