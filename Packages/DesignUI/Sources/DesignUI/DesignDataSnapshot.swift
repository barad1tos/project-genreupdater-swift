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

public struct DesignDataSnapshot: Equatable, Sendable {
    public let health: HealthSnapshot
    public let pipelineActivity: PipelineActivitySnapshot
    public let pendingVerification: PendingVerificationSnapshot
    public let coverage: [CoverageBucket]
    public let issues: [Issue]
    public let metrics: [MetricTile]
    public let activity: [ActivityItem]
    public let artists: [Artist]
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

    public init(
        health: HealthSnapshot,
        pipelineActivity: PipelineActivitySnapshot,
        pendingVerification: PendingVerificationSnapshot,
        coverage: [CoverageBucket],
        issues: [Issue],
        metrics: [MetricTile],
        activity: [ActivityItem],
        artists: [Artist],
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
        isPreviewBacked: Bool
    ) {
        self.health = health
        self.pipelineActivity = pipelineActivity
        self.pendingVerification = pendingVerification
        self.coverage = coverage
        self.issues = issues
        self.metrics = metrics
        self.activity = activity
        self.artists = artists
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

public struct DesignSettingsSnapshot: Equatable, Sendable {
    public static let preview = Self(
        updateBehavior: .both,
        minimumConfidencePercent: 70,
        releaseYearRestoreThresholdYears: 5,
        testArtists: ["Aphex Twin", "Boards of Canada"],
        appearanceMode: .system,
        isFastAnimationsEnabled: false,
        isPostWriteVerificationRequired: true
    )

    public let updateBehavior: DesignUpdateBehavior
    public let minimumConfidencePercent: Double
    public let releaseYearRestoreThresholdYears: Int
    public let testArtists: [String]
    public let appearanceMode: DesignAppearanceMode
    public let isFastAnimationsEnabled: Bool
    public let isPostWriteVerificationRequired: Bool
    /// Display-only experience gate (ADR 0002): false hides the Advanced
    /// settings tab; every setting behind it stays effective.
    public let isAdvancedExperience: Bool

    public init(
        updateBehavior: DesignUpdateBehavior,
        minimumConfidencePercent: Double,
        releaseYearRestoreThresholdYears: Int,
        testArtists: [String],
        appearanceMode: DesignAppearanceMode = .system,
        isFastAnimationsEnabled: Bool = false,
        isPostWriteVerificationRequired: Bool,
        isAdvancedExperience: Bool = true
    ) {
        self.updateBehavior = updateBehavior
        self.minimumConfidencePercent = minimumConfidencePercent
        self.releaseYearRestoreThresholdYears = releaseYearRestoreThresholdYears
        self.testArtists = testArtists
        self.appearanceMode = appearanceMode
        self.isFastAnimationsEnabled = isFastAnimationsEnabled
        self.isPostWriteVerificationRequired = isPostWriteVerificationRequired
        self.isAdvancedExperience = isAdvancedExperience
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
