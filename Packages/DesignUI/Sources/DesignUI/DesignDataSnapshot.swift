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
    public let syncStatusText: String
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
        syncStatusText: String,
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
        self.syncStatusText = syncStatusText
        self.isPreviewBacked = isPreviewBacked
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

public extension DesignDataSnapshot {
    static var preview: Self {
        MockData().designSnapshot
    }
}
