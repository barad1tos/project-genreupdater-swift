import Core
import DesignUI
import Foundation

extension ActivitySnapshotAdapter {
    static func makeReportEntries(from entries: [Core.ChangeLogEntry]) -> [Core.ChangeLogEntry] {
        Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(reportEntryLimit))
    }

    static func makeChangeLog(from entries: [Core.ChangeLogEntry], now: Date) -> [LogEntry] {
        entries.map { entry in
            LogEntry(
                id: entry.id.uuidString,
                time: relativeElapsedLabel(since: entry.timestamp, now: now),
                type: makeDesignChangeType(from: entry.changeType),
                track: makeChangeLogTrackTitle(from: entry),
                artist: entry.artist,
                old: makeChangeLogOldValue(from: entry),
                new: makeChangeLogNewValue(from: entry),
                conf: nil
            )
        }
    }

    static func makeReportStats(from entries: [Core.ChangeLogEntry]) -> ReportStats {
        ReportStats(
            processed: entries.count,
            genres: entries.count { $0.newGenre != nil },
            years: entries.count { $0.newYear != nil }
        )
    }

    static func makeGenreDistribution(from entries: [Core.ChangeLogEntry]) -> [ChartDatum] {
        let updatedGenres = entries.compactMap(\.newGenre)
        let genreCounts = Dictionary(grouping: updatedGenres, by: { $0 }).mapValues { $0.count }
        let sortedGenres = genreCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }

        return sortedGenres
            .prefix(8)
            .map { genre, count in
                ChartDatum(id: stableValueID(prefix: "genre", value: genre), label: genre, count: count)
            }
    }

    static func makeUpdatesOverTime(from entries: [Core.ChangeLogEntry]) -> [ChartDatum] {
        let calendar = Calendar(identifier: .gregorian)
        let groupedByDay = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }

        return groupedByDay.keys.sorted().suffix(12).map { day in
            ChartDatum(
                id: "day-\(Int(day.timeIntervalSince1970))",
                label: day.formatted(.dateTime.month(.abbreviated).day()),
                count: groupedByDay[day]?.count ?? 0
            )
        }
    }

    static func makeYearDistribution(from entries: [Core.ChangeLogEntry]) -> [ChartDatum] {
        let decadeCounts = Dictionary(grouping: entries.compactMap(\.newYear)) { year in
            year / 10 * 10
        }
        .mapValues(\.count)

        return decadeCounts.keys.sorted().map { decade in
            ChartDatum(
                id: "decade-\(decade)",
                label: "\(decade)s",
                count: decadeCounts[decade] ?? 0
            )
        }
    }

    private static func stableValueID(prefix: String, value: String) -> String {
        "\(prefix)-\(value.count)-\(value)"
    }

    private static func makeDesignChangeType(from changeType: Core.ChangeType) -> DesignUI.ChangeType {
        switch changeType {
        case .genreUpdate:
            .genre
        case .yearUpdate:
            .year
        case .trackCleaning:
            .track
        case .albumCleaning:
            .album
        case .artistRename:
            .artist
        case .yearRevert:
            .revert
        }
    }

    private static func makeChangeLogTrackTitle(from entry: Core.ChangeLogEntry) -> String {
        if !entry.trackName.isEmpty {
            return entry.trackName
        }

        if !entry.albumName.isEmpty {
            return entry.albumName
        }

        return entry.trackID
    }

    private static func makeChangeLogOldValue(from entry: Core.ChangeLogEntry) -> String {
        switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre ?? "none"
        case .yearUpdate, .yearRevert:
            entry.oldYear.map(String.init) ?? "none"
        case .trackCleaning:
            entry.oldTrackName ?? entry.trackName
        case .albumCleaning:
            entry.oldAlbumName ?? entry.albumName
        case .artistRename:
            entry.oldArtist ?? entry.artist
        }
    }

    private static func makeChangeLogNewValue(from entry: Core.ChangeLogEntry) -> String {
        switch entry.changeType {
        case .genreUpdate:
            entry.newGenre ?? "none"
        case .yearUpdate, .yearRevert:
            entry.newYear.map(String.init) ?? "none"
        case .trackCleaning:
            entry.newTrackName ?? entry.trackName
        case .albumCleaning:
            entry.newAlbumName ?? entry.albumName
        case .artistRename:
            entry.newArtist ?? entry.artist
        }
    }
}
