import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityReportSnapshot")
struct ActivityReportTests {
    private let scanDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("maps persisted change log entries for read-only reports")
    func mapsPersistedChangeLogEntriesForReadOnlyReports() throws {
        let genreID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let yearID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let renameID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let entries = [
            Core.ChangeLogEntry(
                id: genreID,
                timestamp: scanDate,
                changeType: .genreUpdate,
                trackID: "track-genre",
                artist: "Metallica",
                trackName: "Battery",
                albumName: "Master of Puppets",
                oldGenre: "Metal",
                newGenre: "Thrash Metal"
            ),
            Core.ChangeLogEntry(
                id: yearID,
                timestamp: scanDate.addingTimeInterval(-60),
                changeType: .yearUpdate,
                trackID: "track-year",
                artist: "Radiohead",
                trackName: "Idioteque",
                albumName: "Kid A",
                oldYear: nil,
                newYear: 2000
            ),
            Core.ChangeLogEntry(
                id: renameID,
                timestamp: scanDate.addingTimeInterval(-120),
                changeType: .artistRename,
                trackID: "track-artist",
                artist: "Aphex Twin",
                trackName: "Windowlicker",
                albumName: "Windowlicker",
                oldArtist: "AFX",
                newArtist: "Aphex Twin"
            )
        ]

        let snapshot = makeSnapshot(from: makeInput(changeLogEntries: entries))

        #expect(snapshot.changeLog.map(\.id) == [genreID.uuidString, yearID.uuidString, renameID.uuidString])
        #expect(snapshot.changeLog[0].time == "8m ago")
        #expect(snapshot.changeLog[0].type == .genre)
        #expect(snapshot.changeLog[0].old == "Metal")
        #expect(snapshot.changeLog[0].new == "Thrash Metal")
        #expect(snapshot.changeLog[0].conf == nil)
        #expect(snapshot.changeLog[2].type == .artist)
        #expect(snapshot.changeLog[2].old == "AFX")
        #expect(snapshot.reportStats.processed == 3)
        #expect(snapshot.reportStats.genres == 1)
        #expect(snapshot.reportStats.years == 1)
        #expect(snapshot.genreDistribution.first?.label == "Thrash Metal")
        #expect(snapshot.yearDistribution.first?.label == "2000s")
        #expect(snapshot.updatesOverTime.map(\.count).reduce(0, +) == entries.count)
    }

    @Test("maps persisted change log branch variants for read-only reports")
    func mapsPersistedChangeLogBranchVariantsForReadOnlyReports() throws {
        let trackID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let albumID = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let revertID = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let entries = [
            Core.ChangeLogEntry(
                id: trackID,
                timestamp: scanDate,
                changeType: .trackCleaning,
                trackID: "track-clean",
                artist: "Aphex Twin",
                trackName: "",
                albumName: "Windowlicker",
                oldTrackName: "Windowlicker [Remastered]",
                newTrackName: "Windowlicker"
            ),
            Core.ChangeLogEntry(
                id: albumID,
                timestamp: scanDate.addingTimeInterval(-60),
                changeType: .albumCleaning,
                trackID: "album-clean",
                artist: "Boards of Canada",
                trackName: "Roygbiv",
                albumName: "Music Has the Right to Children",
                oldAlbumName: "Music Has the Right to Children (Expanded)",
                newAlbumName: "Music Has the Right to Children"
            ),
            Core.ChangeLogEntry(
                id: revertID,
                timestamp: scanDate.addingTimeInterval(-120),
                changeType: .yearRevert,
                trackID: "year-revert",
                artist: "Boards of Canada",
                trackName: "",
                albumName: "",
                oldYear: 2024,
                newYear: 1998
            )
        ]

        let snapshot = makeSnapshot(from: makeInput(changeLogEntries: entries))

        #expect(snapshot.changeLog[0].type == .track)
        #expect(snapshot.changeLog[0].track == "Windowlicker")
        #expect(snapshot.changeLog[0].old == "Windowlicker [Remastered]")
        #expect(snapshot.changeLog[0].new == "Windowlicker")
        #expect(snapshot.changeLog[1].type == .album)
        #expect(snapshot.changeLog[1].old == "Music Has the Right to Children (Expanded)")
        #expect(snapshot.changeLog[1].new == "Music Has the Right to Children")
        #expect(snapshot.changeLog[2].type == .revert)
        #expect(snapshot.changeLog[2].track == "year-revert")
        #expect(snapshot.changeLog[2].old == "2024")
        #expect(snapshot.changeLog[2].new == "1998")
        #expect(snapshot.reportStats.processed == 3)
        #expect(snapshot.reportStats.genres == 0)
        #expect(snapshot.reportStats.years == 1)
    }

    @Test("keeps genre chart identifiers collision proof")
    func keepsGenreChartIdentifiersCollisionProof() throws {
        let dashedID = try #require(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let spacedID = try #require(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let entries = [
            Core.ChangeLogEntry(
                id: dashedID,
                timestamp: scanDate,
                changeType: .genreUpdate,
                trackID: "genre-dashed",
                artist: "Artist",
                trackName: "Track",
                albumName: "Album",
                newGenre: "Hip-Hop"
            ),
            Core.ChangeLogEntry(
                id: spacedID,
                timestamp: scanDate.addingTimeInterval(-60),
                changeType: .genreUpdate,
                trackID: "genre-spaced",
                artist: "Artist",
                trackName: "Track",
                albumName: "Album",
                newGenre: "Hip Hop"
            )
        ]

        let snapshot = makeSnapshot(from: makeInput(changeLogEntries: entries))
        let identifiers = snapshot.genreDistribution.map(\.id)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.contains("genre-7-Hip-Hop"))
        #expect(identifiers.contains("genre-7-Hip Hop"))
    }

    @Test("maps reports projection into run history")
    func mapsReportsProjectionIntoRunHistory() {
        let run = ReportsRunItem(
            id: "run-1",
            state: .completed,
            stateLabel: "Completed",
            triggerLabel: "Manual check",
            startedLabel: "2m ago",
            modeLabel: "Preview",
            scopeLabel: "Test artists (2)",
            durationLabel: "45s",
            changeCountLabel: "12 changes",
            failureSummary: nil
        )
        let projection = ReportsProjection(revision: .initial, runs: [run], skippedCorruptedCount: 2)

        let snapshot = ActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(),
            activityProjection: .empty(),
            reportsProjection: projection
        )

        #expect(snapshot.runHistory.count == 1)
        #expect(snapshot.runHistory.first?.id == "run-1")
        #expect(snapshot.runHistory.first?.stateLabel == "Completed")
        #expect(snapshot.runHistory.first?.modeLabel == "Preview")
        #expect(snapshot.runHistory.first?.scopeLabel == "Test artists (2)")
        #expect(snapshot.runHistorySkippedCount == 2)
    }

    @Test("omitted reports projection yields empty run history")
    func omittedReportsProjectionYieldsEmptyRunHistory() {
        let snapshot = makeSnapshot(from: makeInput())

        #expect(snapshot.runHistory.isEmpty)
        #expect(snapshot.runHistorySkippedCount == 0)
    }

    private func makeSnapshot(from input: DesignActivitySnapshotInput) -> DesignDataSnapshot {
        ActivitySnapshotAdapter.makeSnapshot(from: input, activityProjection: .empty())
    }

    private func makeInput(changeLogEntries: [Core.ChangeLogEntry] = []) -> DesignActivitySnapshotInput {
        DesignActivitySnapshotInput(
            tracks: [],
            metricsSnapshot: nil,
            lastScanDate: nil,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty,
            pendingVerification: nil,
            changeLogEntries: changeLogEntries,
            isAutoSyncRunning: false,
            runLifecycle: nil,
            settings: .preview,
            now: now
        )
    }
}
