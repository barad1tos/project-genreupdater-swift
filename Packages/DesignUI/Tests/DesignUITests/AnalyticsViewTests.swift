import Foundation
import Testing
@testable import DesignUI

@Suite("Analytics report")
struct AnalyticsViewTests {
    @Test("analytics is visible only in Advanced experience")
    func routePolicy() {
        #expect(SidebarRoutePolicy.routes(isAdvancedExperience: true) == [
            .activity, .browse, .reports, .analytics, .update,
        ])
        #expect(SidebarRoutePolicy.routes(isAdvancedExperience: false) == [
            .activity, .browse, .reports, .update,
        ])
        #expect(SidebarRoutePolicy.fallback(for: .analytics, isAdvancedExperience: false) == .reports)
        #expect(SidebarRoutePolicy.fallback(for: .analytics, isAdvancedExperience: true) == .analytics)
    }

    @Test("populated reports keep every stable section")
    func populatedSections() {
        #expect(AnalyticsSection.order(for: .populated) == [
            .header, .summary, .distribution, .operations, .recentEvents,
        ])
        #expect(AnalyticsSection.order(for: .disabled) == [.header, .state])
        #expect(AnalyticsSection.order(for: .empty) == [.header, .state])
        #expect(AnalyticsSection.order(for: .unavailable) == [.header, .state])
    }

    @Test("state actions distinguish settings, retry, and passive empty content")
    func stateActions() {
        #expect(AnalyticsStateAction.forState(.disabled) == .openSettings)
        #expect(AnalyticsStateAction.forState(.unavailable) == .retry)
        #expect(AnalyticsStateAction.forState(.empty) == nil)
        #expect(AnalyticsStateAction.forState(.populated) == nil)
    }

    @Test("snapshot carries presentation facts without access gating")
    func snapshotContract() {
        let snapshot = DesignAnalyticsSnapshot(
            state: .populated,
            selectedWindow: .last24Hours,
            summary: .init(
                calls: 3,
                succeeded: 2,
                failed: 1,
                cancelled: 0,
                successRate: 2.0 / 3.0,
                totalDuration: "3.0 s",
                averageDuration: "1.0 s",
                p95Duration: "2.0 s"
            ),
            distribution: [
                .init(id: "short", label: "Short", count: 2, tone: .success),
                .init(id: "long", label: "Long", count: 1, tone: .warning),
            ],
            operations: [
                .init(
                    id: "music-app-fetch",
                    name: "Music.app fetch",
                    category: "Music.app",
                    calls: 3,
                    successRate: "67%",
                    totalDuration: "3.0 s",
                    averageDuration: "1.0 s",
                    p95Duration: "2.0 s"
                ),
            ],
            recentEvents: [
                .init(
                    id: UUID(),
                    operation: "Music.app fetch",
                    startedAt: "Now",
                    duration: "2.0 s",
                    outcome: .failed
                ),
            ]
        )

        #expect(snapshot.availableWindows == DesignAnalyticsWindow.allCases)
        #expect(snapshot.operations.map(\.id) == ["music-app-fetch"])
        #expect(snapshot.recentEvents.map(\.outcome) == [.failed])
    }
}
