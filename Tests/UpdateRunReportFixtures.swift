import Core
import Services
@testable import Genre_Updater

/// Shared fixtures for the `UpdateRunReport` test suites.
///
/// Extracted so the report tests can live in focused, per-theme files
/// (grouping, filtering, plain text, operational) without duplicating setup.
enum UpdateRunReportFixtures {
    static func makeEntries(
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

    static func makePureRockFuryChange(changeType: ChangeType) -> ChangeLogEntry {
        ChangeLogEntry(
            changeType: changeType,
            trackID: "done-track",
            artist: "Clutch",
            trackName: "Pure Rock Fury",
            albumName: "Pure Rock Fury"
        )
    }

    static func makePureRockFuryYearChange() -> ChangeLogEntry {
        var changedYear = makePureRockFuryChange(changeType: .yearUpdate)
        changedYear.oldYear = 1999
        changedYear.newYear = 2001
        return changedYear
    }

    static func makeMixedRunHealthReport(
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

    /// Builds a `ChangeLogEntry` of `changeType` for `trackID`, applying `configure`
    /// to set the relevant old/new fields for that change type.
    static func makeChange(
        _ changeType: ChangeType,
        _ trackID: String,
        configure: (inout ChangeLogEntry) -> Void
    ) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: changeType,
            trackID: trackID,
            artist: "Clutch",
            trackName: "Track",
            albumName: "Album"
        )
        configure(&entry)
        return entry
    }
}
