import Core
import Foundation

enum AnalyticsBuilder {
    static func build(
        events: [StoredAnalyticsEvent],
        window: AnalyticsReportWindow,
        configuration: AnalyticsConfig
    ) -> AnalyticsProjection {
        guard configuration.enabled else {
            return .empty(state: .disabled, window: window, isRecordingEnabled: false)
        }
        guard !events.isEmpty else {
            return .empty(state: .empty, window: window, isRecordingEnabled: true)
        }

        let summary = summary(for: events)
        let distribution = distribution(for: events, thresholds: configuration.durationThresholds)
        let operations = Dictionary(grouping: events, by: \.operationValue)
            .map { operationRow(operationValue: $0.key, events: $0.value) }
            .sorted {
                if $0.totalDurationSeconds != $1.totalDurationSeconds {
                    return $0.totalDurationSeconds > $1.totalDurationSeconds
                }
                return $0.operationValue < $1.operationValue
            }
        let recentEvents = events
            .filter { $0.outcome != .succeeded || $0.durationSeconds > configuration.durationThresholds.shortMax }
            .sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt > $1.startedAt
                }
                return $0.id.uuidString > $1.id.uuidString
            }
            .prefix(configuration.recentEventLimit)
            .map {
                AnalyticsRecentEvent(
                    id: $0.id,
                    operationValue: $0.operationValue,
                    displayName: AnalyticsOperation.displayName(for: $0.operationValue),
                    startedAt: $0.startedAt,
                    durationSeconds: $0.durationSeconds,
                    outcome: $0.outcome
                )
            }

        return AnalyticsProjection(
            state: .populated,
            window: window,
            isRecordingEnabled: true,
            summary: summary,
            durationDistribution: distribution,
            operations: operations,
            recentEvents: recentEvents
        )
    }

    private static func operationRow(
        operationValue: String,
        events: [StoredAnalyticsEvent]
    ) -> AnalyticsOperationRow {
        let operation = AnalyticsOperation(rawValue: operationValue)
        let summary = summary(for: events)
        return AnalyticsOperationRow(
            operationValue: operationValue,
            displayName: operation?.displayName ?? AnalyticsOperation.displayName(for: operationValue),
            category: operation?.category,
            calls: summary.calls,
            succeeded: summary.succeeded,
            failed: summary.failed,
            cancelled: summary.cancelled,
            successRate: summary.successRate,
            totalDurationSeconds: summary.totalDurationSeconds,
            averageDurationSeconds: summary.averageDurationSeconds,
            p95DurationSeconds: summary.p95DurationSeconds
        )
    }

    private static func summary(for events: [StoredAnalyticsEvent]) -> AnalyticsSummary {
        let durations = events.map(\.durationSeconds)
        let calls = events.count
        let succeeded = events.count { $0.outcome == .succeeded }
        let failed = events.count { $0.outcome == .failed }
        let cancelled = events.count { $0.outcome == .cancelled }
        let totalDuration = durations.reduce(0, +)
        return AnalyticsSummary(
            calls: calls,
            succeeded: succeeded,
            failed: failed,
            cancelled: cancelled,
            successRate: calls == 0 ? 0 : Double(succeeded) / Double(calls),
            totalDurationSeconds: totalDuration,
            averageDurationSeconds: calls == 0 ? 0 : totalDuration / Double(calls),
            p95DurationSeconds: p95(durations)
        )
    }

    private static func distribution(
        for events: [StoredAnalyticsEvent],
        thresholds: DurationThresholdsConfig
    ) -> AnalyticsDurationDistribution {
        var short = 0
        var medium = 0
        var long = 0
        var veryLong = 0
        for event in events {
            switch event.durationSeconds {
            case ...thresholds.shortMax:
                short += 1
            case ...thresholds.mediumMax:
                medium += 1
            case ...thresholds.longMax:
                long += 1
            default:
                veryLong += 1
            }
        }
        return AnalyticsDurationDistribution(short: short, medium: medium, long: long, veryLong: veryLong)
    }

    private static func p95(_ durations: [Double]) -> Double {
        guard !durations.isEmpty else { return 0 }
        let sorted = durations.sorted()
        let rank = Int(ceil(0.95 * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
