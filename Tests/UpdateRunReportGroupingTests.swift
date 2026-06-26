import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run report grouping")
struct UpdateRunReportGroupingTests {
    @Test("groups successful year changes by artist, album, and value")
    func groupsSuccessfulYearChangesByArtistAlbumAndValue() {
        let foregoneEntries = UpdateRunReportFixtures.makeEntries(
            album: "Foregone",
            count: 13,
            oldYear: 2021,
            newYear: 2023
        )
        let subterraneanEntries = UpdateRunReportFixtures.makeEntries(
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
}
