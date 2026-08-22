import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Analytics app boundary")
@MainActor
struct AnalyticsAppTests {
    @Test("Services projection maps every report fact")
    func projectionMapping() throws {
        let eventID = UUID()
        let summary = AnalyticsSummary(
            calls: 4,
            succeeded: 2,
            failed: 1,
            cancelled: 1,
            totalDurationSeconds: 3,
            averageDurationSeconds: 0.75,
            p95DurationSeconds: 2
        )
        let projection = AnalyticsProjection(
            state: .populated,
            window: .last24Hours,
            isRecordingEnabled: true,
            summary: summary,
            durationDistribution: .init(short: 1, medium: 1, long: 1, veryLong: 1),
            operations: [
                .init(
                    operationValue: AnalyticsOperation.musicAppFetch.rawValue,
                    displayName: "Music.app fetch",
                    category: .library,
                    summary: summary
                ),
            ],
            recentEvents: [
                .init(
                    id: eventID,
                    operationValue: AnalyticsOperation.musicAppFetch.rawValue,
                    displayName: "Music.app fetch",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    durationSeconds: 2,
                    outcome: .failed
                ),
            ]
        )

        let snapshot = try AnalyticsSnapshotAdapter.makeSnapshot(
            from: projection,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )

        #expect(snapshot.state == .populated)
        #expect(snapshot.selectedWindow == .last24Hours)
        #expect(snapshot.summary.calls == 4)
        #expect(snapshot.summary.successRate == 0.5)
        #expect(snapshot.summary.totalDuration == "3.00 s")
        #expect(snapshot.distribution.map(\.count) == [1, 1, 1, 1])
        #expect(snapshot.operations.first?.id == AnalyticsOperation.musicAppFetch.rawValue)
        #expect(snapshot.operations.first?.category == "Library")
        #expect(snapshot.operations.first?.successRate == "50%")
        #expect(snapshot.recentEvents.first?.id == eventID)
        #expect(snapshot.recentEvents.first?.outcome == .failed)
    }

    @Test("analytics window and navigation mapping round-trip")
    func mappingRoundTrip() {
        for window in AnalyticsReportWindow.allCases {
            #expect(AnalyticsSnapshotAdapter
                .serviceWindow(from: AnalyticsSnapshotAdapter.designWindow(from: window)) == window)
        }
        #expect(NavigationCategory.analytics.designRoute == .analytics)
        #expect(NavigationCategory(designRoute: .analytics) == .analytics)
        #expect(NavigationCategory.visibleOrder(isAdvancedExperience: true) == [
            .dashboard, .browse, .reports, .analytics, .update,
        ])
        #expect(NavigationCategory.visibleOrder(isAdvancedExperience: false) == [
            .dashboard, .browse, .reports, .update,
        ])
    }

    @Test("disabled and unavailable state remain distinct")
    func stateMapping() {
        let disabled = AnalyticsProjection(
            state: .disabled,
            window: .currentSession,
            isRecordingEnabled: false,
            summary: .empty,
            durationDistribution: .empty,
            operations: [],
            recentEvents: []
        )
        let unavailable = AnalyticsProjection.unavailable(window: .currentSession, isRecordingEnabled: true)

        #expect(AnalyticsSnapshotAdapter.makeSnapshot(from: disabled).state == .disabled)
        #expect(AnalyticsSnapshotAdapter.makeSnapshot(from: unavailable).state == .unavailable)
    }
}
