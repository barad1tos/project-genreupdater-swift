import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("CachedAnalyticsService")
struct CachedAnalyticsServiceTests {
    @Test("Disabled analytics does not write events")
    func disabledAnalyticsDoesNotWriteEvents() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = AnalyticsConfig()
        configuration.enabled = false
        let service = CachedAnalyticsService(cache: cache, configuration: configuration)

        await service.trackEvent("library.load", duration: .seconds(2), metadata: ["source": "music"])

        let events: [AnalyticsEvent]? = await cache.get(key: CachedAnalyticsService.eventsCacheKey)
        #expect(events == nil)
    }

    @Test("Enabled analytics records bounded events with duration bucket")
    func enabledAnalyticsRecordsBoundedEvents() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.maxEvents = 2
        configuration.durationThresholds.shortMax = 1
        configuration.durationThresholds.mediumMax = 3
        let service = CachedAnalyticsService(cache: cache, configuration: configuration)

        await service.trackEvent("first", duration: .milliseconds(500), metadata: [:])
        await service.trackEvent("second", duration: .seconds(2), metadata: [:])
        await service.trackEvent("third", duration: .seconds(5), metadata: ["source": "snapshot"])

        let events: [AnalyticsEvent]? = await cache.get(key: CachedAnalyticsService.eventsCacheKey)
        #expect(events?.map(\.eventType) == ["second", "third"])
        #expect(events?.first?.durationBucket == "medium")
        #expect(events?.last?.durationBucket == "long")
        #expect(events?.last?.metadata["source"] == "snapshot")
    }
}
