import Core
import Foundation

/// Time range represented by an analytics report.
public enum AnalyticsReportWindow: String, CaseIterable, Equatable, Sendable {
    case currentSession
    case last24Hours
    case last7Days

    func query(now: Date, sessionID: UUID) -> (cutoff: Date?, sessionID: UUID?) {
        switch self {
        case .currentSession:
            (nil, sessionID)
        case .last24Hours:
            (now.addingTimeInterval(-86400), nil)
        case .last7Days:
            (now.addingTimeInterval(-7 * 86400), nil)
        }
    }
}

/// Availability and content state of the analytics report.
public enum AnalyticsReportState: Equatable, Sendable {
    case disabled
    case empty
    case unavailable
    case populated
}

/// Aggregate performance facts for a selected report window.
public struct AnalyticsSummary: Equatable, Sendable {
    public let calls: Int
    public let succeeded: Int
    public let failed: Int
    public let cancelled: Int
    public let successRate: Double
    public let totalDurationSeconds: Double
    public let averageDurationSeconds: Double
    public let p95DurationSeconds: Double

    public init(
        calls: Int,
        succeeded: Int,
        failed: Int,
        cancelled: Int,
        successRate: Double,
        totalDurationSeconds: Double,
        averageDurationSeconds: Double,
        p95DurationSeconds: Double
    ) {
        self.calls = calls
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
        self.successRate = successRate
        self.totalDurationSeconds = totalDurationSeconds
        self.averageDurationSeconds = averageDurationSeconds
        self.p95DurationSeconds = p95DurationSeconds
    }

    public static let empty = Self(
        calls: 0,
        succeeded: 0,
        failed: 0,
        cancelled: 0,
        successRate: 0,
        totalDurationSeconds: 0,
        averageDurationSeconds: 0,
        p95DurationSeconds: 0
    )
}

/// Event counts classified by the active duration thresholds.
public struct AnalyticsDurationDistribution: Equatable, Sendable {
    public let short: Int
    public let medium: Int
    public let long: Int
    public let veryLong: Int

    public init(short: Int, medium: Int, long: Int, veryLong: Int) {
        self.short = short
        self.medium = medium
        self.long = long
        self.veryLong = veryLong
    }

    public static let empty = Self(short: 0, medium: 0, long: 0, veryLong: 0)
}

/// Aggregated metrics for one stable operation identity.
public struct AnalyticsOperationRow: Identifiable, Equatable, Sendable {
    public var id: String {
        operationValue
    }

    public let operationValue: String
    public let displayName: String
    public let category: AnalyticsCategory?
    public let calls: Int
    public let succeeded: Int
    public let failed: Int
    public let cancelled: Int
    public let successRate: Double
    public let totalDurationSeconds: Double
    public let averageDurationSeconds: Double
    public let p95DurationSeconds: Double

    public init(
        operationValue: String,
        displayName: String,
        category: AnalyticsCategory?,
        calls: Int,
        succeeded: Int,
        failed: Int,
        cancelled: Int,
        successRate: Double,
        totalDurationSeconds: Double,
        averageDurationSeconds: Double,
        p95DurationSeconds: Double
    ) {
        self.operationValue = operationValue
        self.displayName = displayName
        self.category = category
        self.calls = calls
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
        self.successRate = successRate
        self.totalDurationSeconds = totalDurationSeconds
        self.averageDurationSeconds = averageDurationSeconds
        self.p95DurationSeconds = p95DurationSeconds
    }
}

/// Privacy-safe recent event shown in the report.
public struct AnalyticsRecentEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let operationValue: String
    public let displayName: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let outcome: AnalyticsOutcome

    public init(
        id: UUID,
        operationValue: String,
        displayName: String,
        startedAt: Date,
        durationSeconds: Double,
        outcome: AnalyticsOutcome
    ) {
        self.id = id
        self.operationValue = operationValue
        self.displayName = displayName
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.outcome = outcome
    }
}

/// Complete UI-facing performance report for one time window.
public struct AnalyticsProjection: Equatable, Sendable {
    public let state: AnalyticsReportState
    public let window: AnalyticsReportWindow
    public let isRecordingEnabled: Bool
    public let summary: AnalyticsSummary
    public let durationDistribution: AnalyticsDurationDistribution
    public let operations: [AnalyticsOperationRow]
    public let recentEvents: [AnalyticsRecentEvent]

    public init(
        state: AnalyticsReportState,
        window: AnalyticsReportWindow,
        isRecordingEnabled: Bool,
        summary: AnalyticsSummary,
        durationDistribution: AnalyticsDurationDistribution,
        operations: [AnalyticsOperationRow],
        recentEvents: [AnalyticsRecentEvent]
    ) {
        self.state = state
        self.window = window
        self.isRecordingEnabled = isRecordingEnabled
        self.summary = summary
        self.durationDistribution = durationDistribution
        self.operations = operations
        self.recentEvents = recentEvents
    }

    public static func unavailable(
        window: AnalyticsReportWindow,
        isRecordingEnabled: Bool
    ) -> Self {
        empty(
            state: .unavailable,
            window: window,
            isRecordingEnabled: isRecordingEnabled
        )
    }

    static func empty(
        state: AnalyticsReportState,
        window: AnalyticsReportWindow,
        isRecordingEnabled: Bool
    ) -> Self {
        Self(
            state: state,
            window: window,
            isRecordingEnabled: isRecordingEnabled,
            summary: .empty,
            durationDistribution: .empty,
            operations: [],
            recentEvents: []
        )
    }
}
