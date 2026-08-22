import Core
import DesignUI
import Foundation
import Services

enum AnalyticsRefreshPolicy {
    static let debounce: Duration = .milliseconds(150)
}

enum AnalyticsSnapshotAdapter {
    static func makeSnapshot(
        from projection: AnalyticsProjection,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> DesignAnalyticsSnapshot {
        DesignAnalyticsSnapshot(
            state: designState(from: projection.state),
            selectedWindow: designWindow(from: projection.window),
            summary: DesignAnalyticsSummary(
                calls: projection.summary.calls,
                succeeded: projection.summary.succeeded,
                failed: projection.summary.failed,
                cancelled: projection.summary.cancelled,
                successRate: projection.summary.successRate,
                totalDuration: duration(projection.summary.totalDurationSeconds, locale: locale),
                averageDuration: duration(projection.summary.averageDurationSeconds, locale: locale),
                p95Duration: duration(projection.summary.p95DurationSeconds, locale: locale)
            ),
            distribution: distribution(from: projection.durationDistribution),
            operations: projection.operations.map { makeOperation($0, locale: locale) },
            recentEvents: projection.recentEvents.map {
                DesignAnalyticsEvent(
                    id: $0.id,
                    operation: $0.displayName,
                    startedAt: eventDate($0.startedAt, locale: locale, timeZone: timeZone),
                    duration: duration($0.durationSeconds, locale: locale),
                    outcome: designOutcome(from: $0.outcome)
                )
            }
        )
    }

    static func designWindow(from window: AnalyticsReportWindow) -> DesignAnalyticsWindow {
        switch window {
        case .currentSession: .currentSession
        case .last24Hours: .last24Hours
        case .last7Days: .last7Days
        }
    }

    static func serviceWindow(from window: DesignAnalyticsWindow) -> AnalyticsReportWindow {
        switch window {
        case .currentSession: .currentSession
        case .last24Hours: .last24Hours
        case .last7Days: .last7Days
        }
    }

    private static func designState(from state: AnalyticsReportState) -> DesignAnalyticsState {
        switch state {
        case .disabled: .disabled
        case .empty: .empty
        case .unavailable: .unavailable
        case .populated: .populated
        }
    }

    private static func designOutcome(from outcome: AnalyticsOutcome) -> DesignAnalyticsOutcome {
        switch outcome {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    private static func distribution(
        from value: AnalyticsDurationDistribution
    ) -> [DesignAnalyticsBucket] {
        [
            DesignAnalyticsBucket(id: "short", label: "Short", count: value.short, tone: .success),
            DesignAnalyticsBucket(id: "medium", label: "Medium", count: value.medium, tone: .info),
            DesignAnalyticsBucket(id: "long", label: "Long", count: value.long, tone: .warning),
            DesignAnalyticsBucket(id: "very-long", label: "Very long", count: value.veryLong, tone: .error),
        ]
    }

    private static func makeOperation(_ row: AnalyticsOperationRow, locale: Locale) -> DesignAnalyticsOperation {
        DesignAnalyticsOperation(
            id: row.operationValue,
            name: row.displayName,
            category: categoryName(row.category),
            calls: row.calls,
            successRate: row.successRate.formatted(.percent.precision(.fractionLength(0)).locale(locale)),
            totalDuration: duration(row.totalDurationSeconds, locale: locale),
            averageDuration: duration(row.averageDurationSeconds, locale: locale),
            p95Duration: duration(row.p95DurationSeconds, locale: locale)
        )
    }

    private static func categoryName(_ category: AnalyticsCategory?) -> String {
        switch category {
        case .library: "Library"
        case .appleScript: "AppleScript"
        case .provider: "Provider"
        case .cache: "Cache"
        case .determination: "Determination"
        case .write: "Write"
        case nil: "Other"
        }
    }

    private static func duration(_ seconds: Double, locale: Locale) -> String {
        guard seconds >= 0.001 else {
            return "\((seconds * 1000).formatted(.number.precision(.fractionLength(0)).locale(locale))) ms"
        }
        return "\(seconds.formatted(.number.precision(.fractionLength(2)).locale(locale))) s"
    }

    private static func eventDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        return date.formatted(format)
    }
}
