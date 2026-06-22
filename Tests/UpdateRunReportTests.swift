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
        #expect(report.plainTextSummary.contains("Needs Attention"))
        #expect(
            report.plainTextSummary
                .contains("- Unknown track (Track ID: raw-id): No failure details were captured for this run.")
        )
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

    @Test("falls back to completed entries when batch result is unavailable")
    func fallsBackToCompletedEntriesWhenBatchResultIsUnavailable() {
        var unchangedEntry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "foregone-unchanged",
            artist: "In Flames",
            trackName: "Foregone Unchanged",
            albumName: "Foregone"
        )
        unchangedEntry.oldGenre = "Metal"
        unchangedEntry.newGenre = "Metal"

        var literalNoneEntry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "foregone-none",
            artist: "In Flames",
            trackName: "Foregone None",
            albumName: "Foregone"
        )
        literalNoneEntry.oldGenre = nil
        literalNoneEntry.newGenre = "none"

        let report = UpdateRunReport(
            result: nil,
            completedEntries: [unchangedEntry, literalNoneEntry]
                + makeEntries(
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
        #expect(report.changedEntries.map(\.trackID) == ["foregone-none", "Foregone-1"])
        #expect(report.changedTrackCount == 2)
        #expect(report.skippedCount == 1)
        #expect(report.scannedTrackCount == 2)
    }

    @Test("summarizes change breakdown by type in report output")
    func summarizesChangeBreakdownByTypeInReportOutput() {
        var genreEntry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "foregone-1",
            artist: "In Flames",
            trackName: "State of Slow Decay",
            albumName: "Foregone"
        )
        genreEntry.oldGenre = "Melodic Death Metal"
        genreEntry.newGenre = "Metal"

        var albumCleaningEntry = ChangeLogEntry(
            changeType: .albumCleaning,
            trackID: "foregone-1",
            artist: "In Flames",
            trackName: "State of Slow Decay",
            albumName: "Foregone (Deluxe Edition)"
        )
        albumCleaningEntry.oldAlbumName = "Foregone (Deluxe Edition)"
        albumCleaningEntry.newAlbumName = "Foregone"

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: makeEntries(album: "Foregone", count: 2, oldYear: 2021, newYear: 2023)
                    + [genreEntry, albumCleaningEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: ["In Flames"]
        )

        #expect(report.changeBreakdown.map(\.changeType) == [.albumCleaning, .genreUpdate, .yearUpdate])
        #expect(report.changeBreakdown.map(\.changeCount) == [1, 1, 2])
        #expect(report.changeBreakdown.map(\.trackCount) == [1, 1, 2])
        #expect(report.changeBreakdown.map(\.albumCount) == [1, 1, 1])
        #expect(report.plainTextSummary.contains("Change Breakdown"))
        #expect(report.plainTextSummary.contains("- Album: 1 change, 1 track, 1 album"))
        #expect(report.plainTextSummary.contains("- Year: 2 changes, 2 tracks, 1 album"))
    }

    @Test("plain text report sorts changed albums by artist and album")
    func plainTextReportSortsChangedAlbumsByArtistAndAlbum() throws {
        var zetaEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "zeta-track",
            artist: "Zeta",
            trackName: "Second",
            albumName: "Later Album"
        )
        zetaEntry.oldYear = 2000
        zetaEntry.newYear = 2001

        var alphaYearEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "alpha-year-track",
            artist: "Alpha",
            trackName: "First",
            albumName: "Early Album"
        )
        alphaYearEntry.oldYear = 1990
        alphaYearEntry.newYear = 1991

        var alphaGenreEntry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "alpha-genre-track",
            artist: "Alpha",
            trackName: "Third",
            albumName: "Early Album"
        )
        alphaGenreEntry.oldGenre = "Alternative"
        alphaGenreEntry.newGenre = "Rock"

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [zetaEntry, alphaYearEntry, alphaGenreEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: []
        )

        #expect(report.albumGroups.map(\.title) == [
            "Alpha - Early Album",
            "Alpha - Early Album",
            "Zeta - Later Album",
        ])
        #expect(report.albumGroups.map(\.changeType) == [.yearUpdate, .genreUpdate, .yearUpdate])
        let alphaPosition = try #require(report.plainTextSummary.range(of: "- Alpha - Early Album: Year"))
        let zetaPosition = try #require(report.plainTextSummary.range(of: "- Zeta - Later Album"))
        #expect(alphaPosition.lowerBound < zetaPosition.lowerBound)
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

    @Test("filters no-op changes from run report")
    func filtersNoOpChangesFromRunReport() {
        var unchangedGenre = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "genre-1",
            artist: "Clutch",
            trackName: "American Sleep",
            albumName: "Pure Rock Fury"
        )
        unchangedGenre.oldGenre = "Rock"
        unchangedGenre.newGenre = "Rock"

        var literalNoneGenre = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "genre-none",
            artist: "Clutch",
            trackName: "Big News I",
            albumName: "Clutch"
        )
        literalNoneGenre.oldGenre = nil
        literalNoneGenre.newGenre = "none"

        var changedYear = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "year-1",
            artist: "Clutch",
            trackName: "Pure Rock Fury",
            albumName: "Pure Rock Fury"
        )
        changedYear.oldYear = 1999
        changedYear.newYear = 2001

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [unchangedGenre, literalNoneGenre, changedYear],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: ["Clutch"]
        )

        #expect(report.changedEntries.map(\.trackID) == ["genre-none", "year-1"])
        #expect(report.changedTrackCount == 2)
        #expect(report.changeBreakdown.map(\.changeType) == [.genreUpdate, .yearUpdate])
        #expect(report.plainTextSummary.contains("- Genre: 1 change, 1 track, 1 album"))
        #expect(report.plainTextSummary.contains("- Year: 1 change, 1 track, 1 album"))
        #expect(report.plainTextSummary.contains("Genre none -> none"))
    }

    @Test("prints no-change summary when all entries are no-ops")
    func printsNoChangeSummaryWhenAllEntriesAreNoOps() {
        var unchangedYear = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "year-1",
            artist: "Clutch",
            trackName: "Pure Rock Fury",
            albumName: "Pure Rock Fury"
        )
        unchangedYear.oldYear = 2001
        unchangedYear.newYear = 2001

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [unchangedYear],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: ["Clutch"]
        )

        #expect(report.changedEntries.isEmpty)
        #expect(report.changeBreakdown.isEmpty)
        #expect(report.albumGroups.isEmpty)
        #expect(report.plainTextSummary.contains("No changes were made during this run."))
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
