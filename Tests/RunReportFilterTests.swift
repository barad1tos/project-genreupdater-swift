import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run report filtering")
struct RunReportFilterTests {
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
                + UpdateRunReportFixtures.makeEntries(
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
                entries: UpdateRunReportFixtures.makeEntries(album: "Foregone", count: 2, oldYear: 2021, newYear: 2023)
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

    @Test("summarizes non-change outcomes by operation and reason")
    func summarizesNonChangeOutcomesByOperationAndReason() {
        var unchangedGenre = UpdateRunReportFixtures.makePureRockFuryChange(changeType: .genreUpdate)
        unchangedGenre.oldGenre = "Rock"
        unchangedGenre.newGenre = "Rock"

        var unchangedYear = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "year-no-op",
            artist: "Clutch",
            trackName: "Pure Rock Fury",
            albumName: "Pure Rock Fury"
        )
        unchangedYear.oldYear = 2001
        unchangedYear.newYear = 2001

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                noOpEntries: [unchangedGenre, unchangedYear],
                failedTrackIDs: ["failed-one", "failed-two"],
                errorDescriptions: ["Write denied", "AppleScript ID missing"]
            ),
            completedEntries: [],
            trackStatuses: [
                "failed-one": .failed("Write denied"),
                "failed-two": .failed("AppleScript ID missing"),
                "skipped-track": .skipped,
            ],
            tracks: [
                Track(
                    id: "failed-one",
                    name: "American Sleep",
                    artist: "Clutch",
                    album: "Pure Rock Fury"
                ),
                Track(
                    id: "failed-two",
                    name: "Brazenhead",
                    artist: "Clutch",
                    album: "Pure Rock Fury"
                ),
                Track(
                    id: "skipped-track",
                    name: "Immortal",
                    artist: "Clutch",
                    album: "Pure Rock Fury"
                ),
            ],
            testArtists: ["Clutch"]
        )

        let failures = report.outcomeBreakdown.filter { $0.outcome == .failed }
        #expect(failures.map(\.reason) == ["AppleScript ID missing", "Write denied"])
        #expect(failures.map(\.count) == [1, 1])

        let summary = report.plainTextSummary
        #expect(summary.contains("Outcome Breakdown"))
        #expect(summary.contains("- No-op Genre: 1 no-op, 1 track, 1 album"))
        #expect(summary.contains("- No-op Year: 1 no-op, 1 track, 1 album"))
        #expect(summary.contains("- Skipped Processing: 1 skipped track, 1 track, 1 album, Skipped before write"))
        #expect(summary.contains("- Failed Processing: 1 failure, 1 track, 1 album, AppleScript ID missing"))
        #expect(summary.contains("- Failed Processing: 1 failure, 1 track, 1 album, Write denied"))
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

    @Test("filters real changes across cleaning, rename, and revert change types")
    func filtersRealChangesAcrossCleaningRenameAndRevert() {
        let entries = [
            UpdateRunReportFixtures.makeChange(.trackCleaning, "track-real") {
                $0.oldTrackName = "Spacegrass (Remastered)"
                $0.newTrackName = "Spacegrass"
            },
            UpdateRunReportFixtures.makeChange(.trackCleaning, "track-noop") {
                $0.oldTrackName = "Spacegrass"
                $0.newTrackName = "Spacegrass"
            },
            UpdateRunReportFixtures.makeChange(.albumCleaning, "album-real") {
                $0.oldAlbumName = "Blast Tyrant (Deluxe Edition)"
                $0.newAlbumName = "Blast Tyrant"
            },
            UpdateRunReportFixtures.makeChange(.albumCleaning, "album-noop") {
                $0.oldAlbumName = "Blast Tyrant"
                $0.newAlbumName = "Blast Tyrant"
            },
            UpdateRunReportFixtures.makeChange(.artistRename, "rename-real") {
                $0.oldArtist = "clutch"
                $0.newArtist = "Clutch"
            },
            UpdateRunReportFixtures.makeChange(.artistRename, "rename-noop") {
                $0.oldArtist = "Clutch"
                $0.newArtist = "Clutch"
            },
            UpdateRunReportFixtures.makeChange(.yearRevert, "revert-real") {
                $0.oldYear = 2010
                $0.newYear = 2009
            },
            UpdateRunReportFixtures.makeChange(.yearRevert, "revert-noop") {
                $0.oldYear = 2009
                $0.newYear = 2009
            },
        ]

        let report = UpdateRunReport(
            result: BatchUpdateResult(entries: entries, failedTrackIDs: [], errorDescriptions: []),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: ["Clutch"]
        )

        #expect(report.changedEntries.map(\.trackID) == [
            "track-real", "album-real", "rename-real", "revert-real",
        ])
        #expect(report.changedTrackCount == 4)
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
        let summary = report.plainTextSummary
        #expect(summary.contains("No Changes"))
        #expect(summary.contains("No metadata changes were made during this run."))
        #expect(summary.contains("No changes were made during this run.") == false)
    }
}
