import SwiftUI

// MARK: - Navigation

public enum Route: Hashable, Sendable {
    case activity, browse, reports, update, settings
}

public enum BrowseFilter: String, CaseIterable, Identifiable, Sendable {
    case all, missingGenre, missingYear, conflicts
    public var id: String {
        rawValue
    }
    public var label: String {
        switch self {
        case .all: "All"
        case .missingGenre: "Missing genre"
        case .missingYear: "Missing year"
        case .conflicts: "Conflicts"
        }
    }
}

// MARK: - Snapshot (subset of LibraryDashboardSnapshot)

public struct HealthSnapshot: Equatable, Sendable {
    public let health: Double // 0...1 composite
    public let genre: Double
    public let year: Double
    public let consistency: Double
    public let totalTracks: Int
    public let totalAlbums: Int?
    public let missingGenre: Int
    public let missingYear: Int
    public let completeMetadata: Int
    public let ready: Int // staged updates
    public let pendingVerification: Int
    public let protectedFiles: Int
    public let writeErrors: Int
    public let recentlyAdded: Int
    public let lastScan: String
    public let nextRun: String
    public let source: String
    public let library: String

    public init(
        health: Double,
        genre: Double,
        year: Double,
        consistency: Double,
        totalTracks: Int,
        totalAlbums: Int? = nil,
        missingGenre: Int,
        missingYear: Int,
        completeMetadata: Int,
        ready: Int,
        pendingVerification: Int,
        protectedFiles: Int,
        writeErrors: Int,
        recentlyAdded: Int,
        lastScan: String,
        nextRun: String,
        source: String,
        library: String
    ) {
        self.health = health
        self.genre = genre
        self.year = year
        self.consistency = consistency
        self.totalTracks = totalTracks
        self.totalAlbums = totalAlbums
        self.missingGenre = missingGenre
        self.missingYear = missingYear
        self.completeMetadata = completeMetadata
        self.ready = ready
        self.pendingVerification = pendingVerification
        self.protectedFiles = protectedFiles
        self.writeErrors = writeErrors
        self.recentlyAdded = recentlyAdded
        self.lastScan = lastScan
        self.nextRun = nextRun
        self.source = source
        self.library = library
    }
}

// MARK: - Activity models

public struct CoverageBucket: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let ratio: Double
    public let tone: Tone

    public init(id: String, label: String, ratio: Double, tone: Tone) {
        self.id = id
        self.label = label
        self.ratio = ratio
        self.tone = tone
    }
}

public struct Issue: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let count: String
    public let unit: String?
    public let tone: Tone
    public let symbol: String
    public let trendDown: String?
    public let route: Route?

    public init(
        id: String,
        label: String,
        count: String,
        unit: String? = nil,
        tone: Tone,
        symbol: String,
        trendDown: String? = nil,
        route: Route? = nil
    ) {
        self.id = id
        self.label = label
        self.count = count
        self.unit = unit
        self.tone = tone
        self.symbol = symbol
        self.trendDown = trendDown
        self.route = route
    }
}

public struct MetricTile: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let symbol: String
    public let tone: Tone
    public let trendUp: Bool?
    public let delta: String?

    public init(
        id: String,
        label: String,
        value: String,
        symbol: String,
        tone: Tone,
        trendUp: Bool? = nil,
        delta: String? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.symbol = symbol
        self.tone = tone
        self.trendUp = trendUp
        self.delta = delta
    }
}

public struct ActivityItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct PendingVerificationSnapshot: Equatable, Sendable {
    public static var unavailable: Self {
        unavailable(reason: "Pending verification data not available for this run")
    }

    public static func unavailable(reason: String) -> Self {
        Self(unavailableReason: reason)
    }

    public let totalAlbums: Int
    public let dueAlbums: Int
    public let skippedByInterval: Int
    public let problematicAlbums: Int
    public let verifiedAlbums: Int
    public let unavailableReason: String?

    public init(
        totalAlbums: Int,
        dueAlbums: Int,
        skippedByInterval: Int,
        problematicAlbums: Int,
        verifiedAlbums: Int
    ) {
        self.totalAlbums = totalAlbums
        self.dueAlbums = dueAlbums
        self.skippedByInterval = skippedByInterval
        self.problematicAlbums = problematicAlbums
        self.verifiedAlbums = verifiedAlbums
        unavailableReason = nil
    }

    private init(unavailableReason: String) {
        totalAlbums = 0
        dueAlbums = 0
        skippedByInterval = 0
        problematicAlbums = 0
        verifiedAlbums = 0
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Library / changes

public struct Album: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let genre: String?
    public let year: Int?
    public let tracks: Int
    public let health: Double

    public init(id: String, name: String, genre: String?, year: Int?, tracks: Int, health: Double) {
        self.id = id
        self.name = name
        self.genre = genre
        self.year = year
        self.tracks = tracks
        self.health = health
    }
}

public struct Artist: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let genre: String
    public let albums: [Album]
    public var totalTracks: Int {
        albums.reduce(0) { $0 + $1.tracks }
    }
    public var indexLetter: String {
        let sortableName = name.hasPrefix("The ") ? String(name.dropFirst(4)) : name
        let leadingCharacter = sortableName.first.map(String.init)?.uppercased() ?? "#"
        return leadingCharacter.range(of: "[A-Z]", options: .regularExpression) != nil ? leadingCharacter : "#"
    }

    public init(id: String, name: String, genre: String, albums: [Album]) {
        self.id = id
        self.name = name
        self.genre = genre
        self.albums = albums
    }
}

public enum ChangeType: String, Sendable {
    case genre, year, track, album, artist, revert

    public var symbol: String {
        switch self {
        case .genre:
            "tag"
        case .year:
            "calendar"
        case .track:
            "music.note"
        case .album:
            "rectangle.stack"
        case .artist:
            "person"
        case .revert:
            "arrow.uturn.backward"
        }
    }

    public var tone: Tone {
        switch self {
        case .genre:
            .purple
        case .year:
            .info
        case .track, .album, .artist:
            .accent
        case .revert:
            .error
        }
    }
}

public struct Change: Identifiable, Equatable, Sendable {
    public let id: String
    public let track: String
    public let artist: String
    public let type: ChangeType
    public let old: String?
    public let new: String
    public let conf: Double

    public init(id: String, track: String, artist: String, type: ChangeType, old: String?, new: String, conf: Double) {
        self.id = id
        self.track = track
        self.artist = artist
        self.type = type
        self.old = old
        self.new = new
        self.conf = conf
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let time: String
    public let type: ChangeType
    public let track: String
    public let artist: String
    public let old: String
    public let new: String
    public let conf: Double?

    public init(
        id: String,
        time: String,
        type: ChangeType,
        track: String,
        artist: String,
        old: String,
        new: String,
        conf: Double?
    ) {
        self.id = id
        self.time = time
        self.type = type
        self.track = track
        self.artist = artist
        self.old = old
        self.new = new
        self.conf = conf
    }
}

public struct RunReportRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let stateLabel: String
    public let tone: Tone
    public let triggerLabel: String
    public let startedLabel: String
    /// Optional for DesignUI previews that are not backed by run projections.
    public let modeLabel: String?
    public let scopeLabel: String?
    public let durationLabel: String?
    public let changeCountLabel: String?
    public let failureSummary: String?

    public init(
        id: String,
        stateLabel: String,
        tone: Tone,
        triggerLabel: String,
        startedLabel: String,
        modeLabel: String? = nil,
        scopeLabel: String? = nil,
        durationLabel: String? = nil,
        changeCountLabel: String? = nil,
        failureSummary: String? = nil
    ) {
        self.id = id
        self.stateLabel = stateLabel
        self.tone = tone
        self.triggerLabel = triggerLabel
        self.startedLabel = startedLabel
        self.modeLabel = modeLabel
        self.scopeLabel = scopeLabel
        self.durationLabel = durationLabel
        self.changeCountLabel = changeCountLabel
        self.failureSummary = failureSummary
    }
}

public struct RunReportTransitionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let stageLabel: String
    public let timeLabel: String

    public init(id: String, stageLabel: String, timeLabel: String) {
        self.id = id
        self.stageLabel = stageLabel
        self.timeLabel = timeLabel
    }
}

public struct RunReportSummaryRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct RunReportDetailSnapshot: Equatable, Sendable {
    public static func unavailable(runID: String) -> Self {
        Self(unavailableRunID: runID)
    }

    public let runID: String
    public let stateLabel: String
    public let tone: Tone
    public let triggerLabel: String
    public let startedLabel: String
    public let durationLabel: String?
    public let scopeLines: [String]
    public let transitions: [RunReportTransitionRow]
    public let summaryItems: [RunReportSummaryRow]
    public let failureMessage: String?
    public let unavailableReason: String?

    public init(
        runID: String,
        stateLabel: String,
        tone: Tone,
        triggerLabel: String,
        startedLabel: String,
        durationLabel: String? = nil,
        scopeLines: [String],
        transitions: [RunReportTransitionRow],
        summaryItems: [RunReportSummaryRow],
        failureMessage: String? = nil
    ) {
        self.runID = runID
        self.stateLabel = stateLabel
        self.tone = tone
        self.triggerLabel = triggerLabel
        self.startedLabel = startedLabel
        self.durationLabel = durationLabel
        self.scopeLines = scopeLines
        self.transitions = transitions
        self.summaryItems = summaryItems
        self.failureMessage = failureMessage
        unavailableReason = nil
    }

    private init(unavailableRunID: String) {
        runID = unavailableRunID
        stateLabel = ""
        tone = .neutral
        triggerLabel = ""
        startedLabel = ""
        durationLabel = nil
        scopeLines = []
        transitions = []
        summaryItems = []
        failureMessage = nil
        unavailableReason = "This run report is no longer available"
    }
}

public struct ChartDatum: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let count: Int

    public init(id: String, label: String, count: Int) {
        self.id = id
        self.label = label
        self.count = count
    }
}

func confidenceTone(_ confidence: Double) -> Tone {
    confidence >= 0.8 ? .success : confidence >= 0.5 ? .warning : .error
}

func healthTone(_ ratio: Double) -> Tone {
    ratio >= 0.9 ? .success : ratio >= 0.6 ? .warning : .error
}
