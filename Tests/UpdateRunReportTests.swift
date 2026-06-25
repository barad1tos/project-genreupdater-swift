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

    @Test("groups collaboration report rows by album identity")
    func groupsCollaborationReportRowsByAlbumIdentity() throws {
        var firstEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "ram-1",
            artist: "Daft Punk feat. Pharrell Williams",
            trackName: "Get Lucky",
            albumName: "Random Access Memories"
        )
        firstEntry.oldYear = 2012
        firstEntry.newYear = 2013
        var secondEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "ram-2",
            artist: "Daft Punk feat. Julian Casablancas",
            trackName: "Instant Crush",
            albumName: "Random Access Memories"
        )
        secondEntry.oldYear = 2012
        secondEntry.newYear = 2013

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [firstEntry, secondEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [
                "ram-1": .done,
                "ram-2": .done,
            ],
            tracks: [
                Track(
                    id: "ram-1",
                    name: "Get Lucky",
                    artist: "Daft Punk feat. Pharrell Williams",
                    album: "Random Access Memories"
                ),
                Track(
                    id: "ram-2",
                    name: "Instant Crush",
                    artist: "Daft Punk feat. Julian Casablancas",
                    album: "Random Access Memories"
                ),
            ],
            testArtists: []
        )

        let group = try #require(report.albumGroups.first)
        let result = try #require(report.albumResults.first)
        #expect(report.albumGroups.count == 1)
        #expect(group.artist == "Daft Punk")
        #expect(group.album == "Random Access Memories")
        #expect(group.changedTrackCount == 2)
        #expect(report.affectedAlbumCount == 1)
        #expect(report.affectedArtistCount == 1)
        #expect(report.changeBreakdown.map(\.albumCount) == [1])
        #expect(report.albumResults.count == 1)
        #expect(result.artist == "Daft Punk")
        #expect(result.tracks.map(\.id).sorted() == ["ram-1", "ram-2"])
    }

    @Test("groups known report rows by normalized album identity key")
    func groupsKnownReportRowsByNormalizedAlbumIdentityKey() throws {
        var firstEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "ram-1",
            artist: "Daft Punk",
            trackName: "Get Lucky",
            albumName: "Random Access Memories"
        )
        firstEntry.oldYear = 2012
        firstEntry.newYear = 2013
        var secondEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "ram-2",
            artist: "daft punk",
            trackName: "Instant Crush",
            albumName: "random access memories"
        )
        secondEntry.oldYear = 2012
        secondEntry.newYear = 2013

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [firstEntry, secondEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [
                "ram-1": .done,
                "ram-2": .done,
            ],
            tracks: [
                Track(
                    id: "ram-1",
                    name: "Get Lucky",
                    artist: "Daft Punk",
                    album: "Random Access Memories"
                ),
                Track(
                    id: "ram-2",
                    name: "Instant Crush",
                    artist: "daft punk",
                    album: "random access memories"
                ),
            ],
            testArtists: []
        )

        let group = try #require(report.albumGroups.first)
        let result = try #require(report.albumResults.first)
        #expect(report.albumGroups.count == 1)
        #expect(group.changedTrackCount == 2)
        #expect(report.affectedAlbumCount == 1)
        #expect(report.affectedArtistCount == 1)
        #expect(report.changeBreakdown.map(\.albumCount) == [1])
        #expect(report.albumResults.count == 1)
        #expect(result.tracks.map(\.id).sorted() == ["ram-1", "ram-2"])
    }

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

    @Test("models operational notes for mixed run health")
    func modelsOperationalNotesForMixedRunHealth() {
        var unchangedGenre = makePureRockFuryChange(changeType: .genreUpdate)
        unchangedGenre.oldGenre = "Rock"
        unchangedGenre.newGenre = "Rock"

        let report = makeMixedRunHealthReport(
            completedEntries: [makePureRockFuryYearChange(), unchangedGenre]
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
        let report = makeMixedRunHealthReport(
            completedEntries: [makePureRockFuryYearChange()],
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

    @Test("summarizes non-change outcomes by operation and reason")
    func summarizesNonChangeOutcomesByOperationAndReason() {
        var unchangedGenre = makePureRockFuryChange(changeType: .genreUpdate)
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

    @Test("Pending verification summary includes skipped and verified counts")
    func pendingSummaryIncludesLifecycleCounts() throws {
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
    func recoverySummaryAppearsInReportAndPlainText() throws {
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

    private func makePureRockFuryChange(changeType: ChangeType) -> ChangeLogEntry {
        ChangeLogEntry(
            changeType: changeType,
            trackID: "done-track",
            artist: "Clutch",
            trackName: "Pure Rock Fury",
            albumName: "Pure Rock Fury"
        )
    }

    private func makePureRockFuryYearChange() -> ChangeLogEntry {
        var changedYear = makePureRockFuryChange(changeType: .yearUpdate)
        changedYear.oldYear = 1999
        changedYear.newYear = 2001
        return changedYear
    }

    private func makeMixedRunHealthReport(
        completedEntries: [ChangeLogEntry],
        displayMode: ChangeDisplayMode = .compact
    ) -> UpdateRunReport {
        UpdateRunReport(
            result: nil,
            completedEntries: completedEntries,
            trackStatuses: [
                "done-track": .done,
                "failed-track": .failed("Write denied"),
                "skipped-track": .skipped,
            ],
            tracks: [
                Track(
                    id: "done-track",
                    name: "Pure Rock Fury",
                    artist: "Clutch",
                    album: "Pure Rock Fury"
                ),
                Track(
                    id: "failed-track",
                    name: "American Sleep",
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
            testArtists: ["Clutch"],
            displayMode: displayMode
        )
    }
}
