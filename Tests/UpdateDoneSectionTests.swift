import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Update done section")
struct UpdateDoneSectionTests {
    @Test("empty filter result does not fall back to unfiltered album")
    func emptyFilterResultDoesNotFallBackToUnfilteredAlbum() {
        var noOpEntry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "noop-track",
            artist: "Artist",
            trackName: "Song",
            albumName: "Album"
        )
        noOpEntry.oldGenre = "Rock"
        noOpEntry.newGenre = "Rock"

        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [],
                noOpEntries: [noOpEntry],
                failedTrackIDs: [],
                errorDescriptions: []
            ),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: []
        )

        let selectedAlbum = UpdateRunAlbumFilter.changed.selectedAlbum(
            in: report.albumResults,
            selectedAlbumID: nil
        )

        #expect(report.albumResults.count == 1)
        #expect(selectedAlbum == nil)
    }
}
