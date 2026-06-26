import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run report plain text")
struct UpdateRunReportPlainTextTests {
    @Test("keeps unknown failures visible with technical fallback")
    func keepsUnknownFailuresVisibleWithTechnicalFallback() throws {
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "known-unknown-album",
            artist: "Unknown artist",
            albumName: "Unknown album"
        )
        entry.oldYear = 1998
        entry.newYear = 1999
        let report = UpdateRunReport(
            result: BatchUpdateResult(entries: [entry], failedTrackIDs: ["raw-id"], errorDescriptions: []),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: []
        )

        #expect(report.failures.first?.title == "Unknown track")
        #expect(report.failures.first?.subtitle == "Track ID: raw-id")
        #expect(report.failures.first?.message == "No failure details were captured for this run.")
        #expect(report.failures.first?.hasKnownTrack == false)
        let album = try #require(report.albumResults.first)
        #expect(report.affectedAlbumCount == 1)
        #expect(album.tracks.count == 2)
        #expect(album.tracks.contains { $0.id == "known-unknown-album" })
        #expect(album.tracks.contains { $0.failureMessage == "No failure details were captured for this run." })
        let summary = report.plainTextSummary
        #expect(summary.contains("- Unknown track (Track ID: raw-id): No failure details were captured for this run."))
        #expect(summary.contains(
            "- Failed Processing: 1 failure, 1 track, No failure details were captured for this run."
        ))
    }

    @Test("changed year rows show original editable year instead of release metadata")
    func changedYearRowsShowOriginalEditableYearInsteadOfReleaseMetadata() {
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

    @Test("plain text summary respects compact and detailed display modes")
    func plainTextSummaryRespectsCompactAndDetailedDisplayModes() {
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "pure-rock-1",
            artist: "Clutch",
            trackName: "American Sleep",
            albumName: "Pure Rock Fury"
        )
        entry.oldYear = 1999
        entry.newYear = 2001

        let compactReport = UpdateRunReport(
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
            testArtists: ["Clutch"],
            displayMode: .compact
        )
        let detailedReport = UpdateRunReport(
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
            testArtists: ["Clutch"],
            displayMode: .detailed
        )

        #expect(compactReport.plainTextSummary.contains("Changed Albums"))
        #expect(compactReport.plainTextSummary.contains("Track Details") == false)
        #expect(compactReport.plainTextSummary.contains("proposed 1999 -> 2001") == false)
        #expect(detailedReport.plainTextSummary.contains("Track Details"))
        #expect(
            detailedReport.plainTextSummary
                .contains("American Sleep: Year 1999; proposed 1999 -> 2001")
        )
    }

    @Test("plain text report includes detailed non-year change values")
    func plainTextReportIncludesDetailedNonYearChangeValues() {
        var trackCleaningEntry = ChangeLogEntry(
            changeType: .trackCleaning,
            trackID: "track-cleaning",
            artist: "Archive",
            trackName: "Demo (Remastered)",
            albumName: "Noise"
        )
        trackCleaningEntry.oldTrackName = "Demo (Remastered)"
        trackCleaningEntry.newTrackName = "Demo"

        var albumCleaningEntry = ChangeLogEntry(
            changeType: .albumCleaning,
            trackID: "album-cleaning",
            artist: "Archive",
            trackName: "Noisy Track",
            albumName: "Noise EP"
        )
        albumCleaningEntry.oldAlbumName = "Noise EP"
        albumCleaningEntry.newAlbumName = "Noise"

        var artistRenameEntry = ChangeLogEntry(
            changeType: .artistRename,
            trackID: "artist-rename",
            artist: "Old Name",
            trackName: "Alias",
            albumName: "Alias"
        )
        artistRenameEntry.oldArtist = "Old Name"
        artistRenameEntry.newArtist = "New Name"

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [trackCleaningEntry, albumCleaningEntry, artistRenameEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: []
        )

        #expect(report.plainTextSummary.contains("- Archive - Noise: Track Demo (Remastered) -> Demo"))
        #expect(report.plainTextSummary.contains("- Archive - Noise EP: Album Noise EP -> Noise"))
        #expect(report.plainTextSummary.contains("- Old Name - Alias: Artist Old Name -> New Name"))
    }
}
