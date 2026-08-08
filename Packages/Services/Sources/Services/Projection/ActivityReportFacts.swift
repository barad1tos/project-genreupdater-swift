import Core
import Foundation

/// One change-log row prepared for display: the derivation (title
/// fallbacks, old/new value selection, relative time vocabulary) is
/// builder truth; adapters only map to design types.
public struct ActivityChangeLogItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let timeLabel: String
    public let changeType: Core.ChangeType
    public let trackTitle: String
    public let artist: String
    public let oldValue: String
    public let newValue: String
}

public struct ActivityReportStats: Equatable, Sendable {
    public let processed: Int
    public let genreUpdates: Int
    public let yearUpdates: Int

    public static let empty = Self(processed: 0, genreUpdates: 0, yearUpdates: 0)

    public init(processed: Int, genreUpdates: Int, yearUpdates: Int) {
        self.processed = processed
        self.genreUpdates = genreUpdates
        self.yearUpdates = yearUpdates
    }
}

public struct ActivityReportBucket: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let count: Int

    public init(id: String, label: String, count: Int) {
        self.id = id
        self.label = label
        self.count = count
    }
}

/// The change-log chart cluster, derived once in the builder (P8): a
/// bounded display log plus stats, genre top-8, 12-day update history,
/// and decade distribution.
public struct ActivityReportFacts: Equatable, Sendable {
    /// Display cap shared with the persistence read: surfaces never
    /// derive from more entries than this.
    public static let entryLimit = 100

    public let changeLog: [ActivityChangeLogItem]
    public let stats: ActivityReportStats
    public let genreDistribution: [ActivityReportBucket]
    public let updatesOverTime: [ActivityReportBucket]
    public let yearDistribution: [ActivityReportBucket]

    public static let empty = Self(
        changeLog: [], stats: .empty, genreDistribution: [], updatesOverTime: [], yearDistribution: []
    )

    public init(
        changeLog: [ActivityChangeLogItem],
        stats: ActivityReportStats,
        genreDistribution: [ActivityReportBucket],
        updatesOverTime: [ActivityReportBucket],
        yearDistribution: [ActivityReportBucket]
    ) {
        self.changeLog = changeLog
        self.stats = stats
        self.genreDistribution = genreDistribution
        self.updatesOverTime = updatesOverTime
        self.yearDistribution = yearDistribution
    }

    public static func make(from entries: [Core.ChangeLogEntry], now: Date) -> Self {
        let bounded = Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(entryLimit))
        return Self(
            changeLog: bounded.map { makeItem(from: $0, now: now) },
            stats: ActivityReportStats(
                processed: bounded.count,
                genreUpdates: bounded.count { $0.newGenre != nil },
                yearUpdates: bounded.count { $0.newYear != nil }
            ),
            genreDistribution: makeGenreDistribution(from: bounded),
            updatesOverTime: makeUpdatesOverTime(from: bounded),
            yearDistribution: makeYearDistribution(from: bounded)
        )
    }

    private static func makeItem(from entry: Core.ChangeLogEntry, now: Date) -> ActivityChangeLogItem {
        ActivityChangeLogItem(
            id: entry.id.uuidString,
            timeLabel: ActivityBuilder.relativeElapsedLabel(since: entry.timestamp, now: now),
            changeType: entry.changeType,
            trackTitle: makeTrackTitle(from: entry),
            artist: entry.artist,
            oldValue: makeOldValue(from: entry),
            newValue: makeNewValue(from: entry)
        )
    }

    private static func makeGenreDistribution(from entries: [Core.ChangeLogEntry]) -> [ActivityReportBucket] {
        let updatedGenres = entries.compactMap(\.newGenre)
        let genreCounts = Dictionary(grouping: updatedGenres, by: { $0 }).mapValues { $0.count }
        let sortedGenres = genreCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }

        return sortedGenres
            .prefix(8)
            .map { genre, count in
                ActivityReportBucket(id: "genre-\(genre.count)-\(genre)", label: genre, count: count)
            }
    }

    private static func makeUpdatesOverTime(from entries: [Core.ChangeLogEntry]) -> [ActivityReportBucket] {
        let calendar = Calendar(identifier: .gregorian)
        let groupedByDay = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }

        return groupedByDay.keys.sorted().suffix(12).map { day in
            ActivityReportBucket(
                id: "day-\(Int(day.timeIntervalSince1970))",
                label: day.formatted(.dateTime.month(.abbreviated).day()),
                count: groupedByDay[day]?.count ?? 0
            )
        }
    }

    private static func makeYearDistribution(from entries: [Core.ChangeLogEntry]) -> [ActivityReportBucket] {
        let decadeCounts = Dictionary(grouping: entries.compactMap(\.newYear)) { year in
            year / 10 * 10
        }
        .mapValues(\.count)

        return decadeCounts.keys.sorted().map { decade in
            ActivityReportBucket(
                id: "decade-\(decade)",
                label: "\(decade)s",
                count: decadeCounts[decade] ?? 0
            )
        }
    }

    private static func makeTrackTitle(from entry: Core.ChangeLogEntry) -> String {
        if !entry.trackName.isEmpty {
            return entry.trackName
        }

        if !entry.albumName.isEmpty {
            return entry.albumName
        }

        return entry.trackID
    }

    private static func makeOldValue(from entry: Core.ChangeLogEntry) -> String {
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

    private static func makeNewValue(from entry: Core.ChangeLogEntry) -> String {
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
