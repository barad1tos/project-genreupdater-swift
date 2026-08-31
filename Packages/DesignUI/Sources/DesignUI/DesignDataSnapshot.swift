import Foundation

/// Shell-zone severity mirrored from the Chrome projection (ADR 0012).
public enum DesignChromeSeverity: String, Equatable, Sendable {
    case nominal
    case attention
    case blocked
}

/// The chrome facts DesignUI shell zones render — never derived locally.
public struct DesignChromeSnapshot: Equatable, Sendable {
    public let syncStatusText: String
    public let syncSeverity: DesignChromeSeverity
    public let processingModeLabel: String
    public let isAutoFixEnabled: Bool
    public let automationLabel: String
    /// Present only when the effective scope narrows the physical library.
    public let narrowedScopeLabel: String?

    public init(
        syncStatusText: String,
        syncSeverity: DesignChromeSeverity,
        processingModeLabel: String,
        isAutoFixEnabled: Bool,
        automationLabel: String,
        narrowedScopeLabel: String?
    ) {
        self.syncStatusText = syncStatusText
        self.syncSeverity = syncSeverity
        self.processingModeLabel = processingModeLabel
        self.isAutoFixEnabled = isAutoFixEnabled
        self.automationLabel = automationLabel
        self.narrowedScopeLabel = narrowedScopeLabel
    }

    public static let preview = Self(
        syncStatusText: "Up to date",
        syncSeverity: .nominal,
        processingModeLabel: "Preview",
        isAutoFixEnabled: false,
        automationLabel: "Manual trigger",
        narrowedScopeLabel: nil
    )
}

/// Composition vehicle only (P8): every field is a formatted mirror of a
/// published projection or a slim view fact — nothing here is derived
/// from raw library state. The change-log/chart cluster is the last
/// view-fed remainder and moves with the backend change-log read path.
public struct DesignDataSnapshot: Equatable, Sendable {
    public let health: HealthSnapshot
    public let pipelineActivity: PipelineActivitySnapshot
    public let pendingVerification: PendingVerificationSnapshot
    public let coverage: [CoverageBucket]
    public let issues: [Issue]
    public let metrics: [MetricTile]
    public let activity: [ActivityItem]
    public let artists: [Artist]
    public let browseScope: DesignBrowseScope?
    public let changes: [Change]
    public let dryRun: DryRunSummary
    public let changeLog: [LogEntry]
    public let reportStats: ReportStats
    public let genreDistribution: [ChartDatum]
    public let updatesOverTime: [ChartDatum]
    public let yearDistribution: [ChartDatum]
    public let runHistory: [RunReportRow]
    public let runHistorySkippedCount: Int
    public let selectedRunReport: RunReportDetailSnapshot?
    public let settings: DesignSettingsSnapshot
    public let syncStatusText: String
    public let chrome: DesignChromeSnapshot
    public let isPreviewBacked: Bool
    public let analytics: DesignAnalyticsSnapshot

    public init(
        health: HealthSnapshot,
        pipelineActivity: PipelineActivitySnapshot,
        pendingVerification: PendingVerificationSnapshot,
        coverage: [CoverageBucket],
        issues: [Issue],
        metrics: [MetricTile],
        activity: [ActivityItem],
        artists: [Artist],
        browseScope: DesignBrowseScope? = nil,
        changes: [Change],
        dryRun: DryRunSummary,
        changeLog: [LogEntry],
        reportStats: ReportStats,
        genreDistribution: [ChartDatum],
        updatesOverTime: [ChartDatum],
        yearDistribution: [ChartDatum],
        runHistory: [RunReportRow] = [],
        runHistorySkippedCount: Int = 0,
        selectedRunReport: RunReportDetailSnapshot? = nil,
        settings: DesignSettingsSnapshot = .preview,
        syncStatusText: String,
        chrome: DesignChromeSnapshot = .preview,
        isPreviewBacked: Bool,
        analytics: DesignAnalyticsSnapshot = .empty
    ) {
        self.health = health
        self.pipelineActivity = pipelineActivity
        self.pendingVerification = pendingVerification
        self.coverage = coverage
        self.issues = issues
        self.metrics = metrics
        self.activity = activity
        self.artists = artists
        self.browseScope = browseScope
        self.changes = changes
        self.dryRun = dryRun
        self.changeLog = changeLog
        self.reportStats = reportStats
        self.genreDistribution = genreDistribution
        self.updatesOverTime = updatesOverTime
        self.yearDistribution = yearDistribution
        self.runHistory = runHistory
        self.runHistorySkippedCount = runHistorySkippedCount
        self.selectedRunReport = selectedRunReport
        self.settings = settings
        self.syncStatusText = syncStatusText
        self.chrome = chrome
        self.isPreviewBacked = isPreviewBacked
        self.analytics = analytics
    }
}

public enum DesignUpdateBehavior: String, CaseIterable, Identifiable, Sendable {
    case genreOnly = "genre_only"
    case yearOnly = "year_only"
    case both

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .genreOnly:
            "Genre"
        case .yearOnly:
            "Year"
        case .both:
            "Both"
        }
    }
}

public enum DesignAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static var supportedModes: [Self] {
        [.dark]
    }

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    public var symbolName: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max"
        case .dark:
            "moon"
        }
    }
}

/// The Discogs connection as a settings display fact — probed, never
/// invented; nil means the probe has not run.
public enum DesignDiscogsState: Equatable, Sendable {
    case noToken
    case connected
    case tokenIssue
    case unverified
}

/// One artist choice projected for settings, including its mirror track count.
public struct DesignArtistOption: Identifiable, Equatable, Sendable {
    public var id: String {
        name
    }

    public let name: String
    public let trackCount: Int

    public init(name: String, trackCount: Int) {
        self.name = name
        self.trackCount = trackCount
    }
}

/// A staged artist selection anchored to the settings revision the user saw.
public struct ArtistScopeChange: Equatable, Sendable {
    /// Selected test artists, or an empty array to remove the restriction and use the full library.
    public let selected: [String]
    public let expectedSettingsRevision: UInt64

    public init(selected: [String], expectedSettingsRevision: UInt64) {
        self.selected = selected
        self.expectedSettingsRevision = expectedSettingsRevision
    }
}

/// Outcome of committing a staged artist scope against its settings revision.
public enum ArtistScopeSaveResult: Equatable, Sendable {
    case accepted
    /// The captured settings revision is no longer current; the persisted scope is unchanged.
    case stale
    /// The scope could not be persisted; the persisted scope is unchanged.
    case failed
}

/// The selected test scope paired with the full searchable library catalog.
public struct DesignArtistScope: Equatable, Sendable {
    public let settingsRevision: UInt64
    /// Selected test artists, or an empty array when runs are unrestricted to the full library.
    public let selected: [String]
    public let options: [DesignArtistOption]
    public let catalogIssue: String?

    public init(
        settingsRevision: UInt64,
        selected: [String],
        options: [DesignArtistOption],
        catalogIssue: String? = nil
    ) {
        self.settingsRevision = settingsRevision
        self.selected = selected
        self.options = options
        self.catalogIssue = catalogIssue
    }

    /// Returns catalog options matching a localized user-entered query.
    public func options(matching query: String) -> [DesignArtistOption] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return options }
        return options.filter { $0.name.localizedStandardContains(trimmedQuery) }
    }
}

/// User-visible tuning for choosing between targeted and bulk Music.app metadata reads.
public struct DesignMetadataReadSettings: Equatable, Sendable {
    public let bulkThreshold: Int
    public let bulkThresholdRange: ClosedRange<Int>

    public init(bulkThreshold: Int, bulkThresholdRange: ClosedRange<Int>) {
        self.bulkThreshold = bulkThreshold
        self.bulkThresholdRange = bulkThresholdRange
    }
}

public struct DesignSettingsSnapshot: Equatable, Sendable {
    /// Presentation-only facts grouped below the parameter ceiling.
    public struct Presentation: Equatable, Sendable {
        public let appearanceMode: DesignAppearanceMode
        public let isFastAnimationsEnabled: Bool
        /// Display-only experience gate (ADR 0002): false hides the
        /// Advanced settings tab; every setting stays effective.
        public let isAdvancedExperience: Bool

        public init(
            appearanceMode: DesignAppearanceMode = .system,
            isFastAnimationsEnabled: Bool = false,
            isAdvancedExperience: Bool = true
        ) {
            self.appearanceMode = appearanceMode
            self.isFastAnimationsEnabled = isFastAnimationsEnabled
            self.isAdvancedExperience = isAdvancedExperience
        }
    }

    public static let preview = Self(
        updateBehavior: .both,
        minimumConfidencePercent: 70,
        releaseYearRestoreThresholdYears: 5,
        metadataReads: DesignMetadataReadSettings(
            bulkThreshold: 25,
            bulkThresholdRange: 1 ... 1000
        ),
        artistScope: DesignArtistScope(
            settingsRevision: 0,
            selected: ["Aphex Twin", "Boards of Canada"],
            options: [
                DesignArtistOption(name: "Aphex Twin", trackCount: 84),
                DesignArtistOption(name: "Boards of Canada", trackCount: 63),
            ]
        ),
        isPostWriteVerificationRequired: true,
        discogsState: .connected
    )

    public let updateBehavior: DesignUpdateBehavior
    public let minimumConfidencePercent: Double
    public let releaseYearRestoreThresholdYears: Int
    public let metadataReads: DesignMetadataReadSettings
    public let artistScope: DesignArtistScope
    public let presentation: Presentation
    public let isPostWriteVerificationRequired: Bool
    public let discogsState: DesignDiscogsState

    public var appearanceMode: DesignAppearanceMode {
        presentation.appearanceMode
    }
    public var isFastAnimationsEnabled: Bool {
        presentation.isFastAnimationsEnabled
    }
    public var isAdvancedExperience: Bool {
        presentation.isAdvancedExperience
    }

    public init(
        updateBehavior: DesignUpdateBehavior,
        minimumConfidencePercent: Double,
        releaseYearRestoreThresholdYears: Int,
        metadataReads: DesignMetadataReadSettings,
        artistScope: DesignArtistScope,
        presentation: Presentation = Presentation(),
        isPostWriteVerificationRequired: Bool,
        discogsState: DesignDiscogsState = .unverified
    ) {
        self.updateBehavior = updateBehavior
        self.minimumConfidencePercent = minimumConfidencePercent
        self.releaseYearRestoreThresholdYears = releaseYearRestoreThresholdYears
        self.metadataReads = metadataReads
        self.artistScope = artistScope
        self.presentation = presentation
        self.isPostWriteVerificationRequired = isPostWriteVerificationRequired
        self.discogsState = discogsState
    }
}

public struct DryRunSummary: Equatable, Sendable {
    public let changes: Int
    public let tracks: Int
    public let averageConfidence: Int
    public let genre: Int
    public let year: Int

    public init(changes: Int, tracks: Int, averageConfidence: Int, genre: Int, year: Int) {
        self.changes = changes
        self.tracks = tracks
        self.averageConfidence = averageConfidence
        self.genre = genre
        self.year = year
    }
}

public struct ReportStats: Equatable, Sendable {
    public let processed: Int
    public let genres: Int
    public let years: Int

    public init(processed: Int, genres: Int, years: Int) {
        self.processed = processed
        self.genres = genres
        self.years = years
    }
}

extension DesignDataSnapshot {
    public static var preview: Self {
        MockData().designSnapshot
    }
}
