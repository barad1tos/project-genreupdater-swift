import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Analytics report builder")
struct AnalyticsBuilderTests {
    @Test("Aggregates outcomes, duration buckets, p95, and operation order")
    func aggregate() {
        let sessionID = UUID()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.durationThresholds.shortMax = 2
        configuration.durationThresholds.mediumMax = 10
        configuration.durationThresholds.longMax = 20
        let events = [
            event(1, sessionID: sessionID, operation: .libraryLoad, duration: 1, outcome: .succeeded),
            event(2, sessionID: sessionID, operationValue: "future.operation", duration: 2, outcome: .succeeded),
            event(3, sessionID: sessionID, operation: .libraryLoad, duration: 5, outcome: .failed),
            event(4, sessionID: sessionID, operation: .batchWrite, duration: 6, outcome: .succeeded),
            event(5, sessionID: sessionID, operation: .batchWrite, duration: 30, outcome: .cancelled),
            event(6, sessionID: sessionID, operation: .libraryLoad, duration: 4, outcome: .degraded),
        ]

        let projection = AnalyticsBuilder.build(
            events: events,
            window: .last24Hours,
            configuration: configuration
        )

        #expect(projection.state == .populated)
        #expect(projection.summary.calls == 6)
        #expect(projection.summary.succeeded == 3)
        #expect(projection.summary.failed == 1)
        #expect(projection.summary.cancelled == 1)
        #expect(projection.summary.degraded == 1)
        #expect(projection.summary.successRate == 0.5)
        #expect(projection.summary.totalDurationSeconds == 48)
        #expect(projection.summary.averageDurationSeconds == 8)
        #expect(projection.summary.p95DurationSeconds == 30)
        #expect(projection.durationDistribution == .init(short: 2, medium: 3, long: 0, veryLong: 1))
        #expect(projection.operations.map(\.operationValue) == ["batch.write", "library.load", "future.operation"])
        #expect(projection.operations[0].calls == 2)
        #expect(projection.operations[0].totalDurationSeconds == 36)
        #expect(projection.operations[0].p95DurationSeconds == 30)
        #expect(projection.operations[2].displayName == "Unknown operation")
        #expect(projection.operations[2].category == nil)
        #expect(projection.recentEvents.map(\.durationSeconds) == [4, 30, 6, 5])
    }

    @Test("Stable operation identity breaks equal-duration ties")
    func stableTieBreak() {
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let sessionID = UUID()
        let projection = AnalyticsBuilder.build(
            events: [
                event(1, sessionID: sessionID, operation: .yearDetermination, duration: 2, outcome: .succeeded),
                event(2, sessionID: sessionID, operation: .genreDetermination, duration: 2, outcome: .succeeded),
            ],
            window: .currentSession,
            configuration: configuration
        )

        #expect(projection.operations.map(\.operationValue) == ["genre.determine", "year.determine"])
    }

    @Test("Recent detail is bounded without truncating aggregate facts")
    func recentDetailLimit() {
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.recentEventLimit = 2
        let sessionID = UUID()
        let events = (1 ... 5).map { index in
            event(
                index,
                sessionID: sessionID,
                operation: .libraryLoad,
                duration: Double(index),
                outcome: .failed
            )
        }

        let projection = AnalyticsBuilder.build(
            events: events,
            window: .currentSession,
            configuration: configuration
        )

        #expect(projection.summary.calls == 5)
        #expect(projection.operations.first?.calls == 5)
        #expect(projection.recentEvents.map(\.durationSeconds) == [5, 4])
    }

    @Test("Empty and single-sample p95 are explicit")
    func p95Boundaries() {
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let empty = AnalyticsBuilder.build(events: [], window: .last7Days, configuration: configuration)
        let single = AnalyticsBuilder.build(
            events: [event(1, sessionID: UUID(), operation: .libraryLoad, duration: 7, outcome: .succeeded)],
            window: .last7Days,
            configuration: configuration
        )

        #expect(empty.state == .empty)
        #expect(empty.summary.p95DurationSeconds == 0)
        #expect(single.summary.p95DurationSeconds == 7)
    }

    @Test("Disabled recording hides retained history")
    func disabled() {
        let projection = AnalyticsBuilder.build(
            events: [event(1, sessionID: UUID(), operation: .libraryLoad, duration: 7, outcome: .failed)],
            window: .last7Days,
            configuration: AnalyticsConfig()
        )

        #expect(projection.state == .disabled)
        #expect(projection.summary == .empty)
        #expect(projection.operations.isEmpty)
        #expect(projection.recentEvents.isEmpty)
    }

    @Test("Storage failure has a distinct unavailable projection")
    func unavailable() {
        let projection = AnalyticsProjection.unavailable(window: .last24Hours, isRecordingEnabled: true)

        #expect(projection.state == .unavailable)
        #expect(projection.window == .last24Hours)
        #expect(projection.isRecordingEnabled)
    }

    private func event(
        _ index: Int,
        sessionID: UUID,
        operation: AnalyticsOperation,
        duration: Double,
        outcome: AnalyticsOutcome
    ) -> StoredAnalyticsEvent {
        event(index, sessionID: sessionID, operationValue: operation.rawValue, duration: duration, outcome: outcome)
    }

    private func event(
        _ index: Int,
        sessionID: UUID,
        operationValue: String,
        duration: Double,
        outcome: AnalyticsOutcome
    ) -> StoredAnalyticsEvent {
        StoredAnalyticsEvent(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
            sessionID: sessionID,
            operationValue: operationValue,
            startedAt: Date(timeIntervalSince1970: Double(index)),
            durationSeconds: duration,
            outcome: outcome
        )
    }
}
