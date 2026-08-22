import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("CachedAnalyticsService")
struct CachedAnalyticsServiceTests {
    @Test("Typed recording preserves the operation identity")
    func typedRecording() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let service = CachedAnalyticsService(cache: cache, configuration: configuration)

        await service.record(.libraryLoad, duration: .seconds(2), outcome: .succeeded)

        let events: [AnalyticsEvent]? = await cache.get(key: CachedAnalyticsService.eventsCacheKey)
        #expect(events?.map(\.eventType) == ["library.load"])
    }

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
        // Python prunes a batch of max(5, cap/10) BEFORE recording, so a cap
        // this small is emptied outright and only the new event survives
        // (analytics.py:305-309). The previous expectation of ["second",
        // "third"] encoded Swift's exact-overflow trim, not Python's.
        #expect(events?.map(\.eventType) == ["third"])
        #expect(events?.last?.durationBucket == "long")
        #expect(events?.last?.metadata["source"] == "snapshot")
    }

    @Test("A non-positive maxEvents disables pruning instead of capping at one")
    func nonPositiveMaxEventsDisablesPruning() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.maxEvents = 0
        let service = CachedAnalyticsService(cache: cache, configuration: configuration)

        for index in 0 ..< 8 {
            await service.trackEvent("event-\(index)", duration: .seconds(1), metadata: [:])
        }

        // Python gates pruning on `0 < max_events`; clamping to 1 turned
        // "no limit" into "keep exactly one".
        let events: [AnalyticsEvent]? = await cache.get(key: CachedAnalyticsService.eventsCacheKey)
        #expect(events?.count == 8)
    }

    @Test("Lowering the cap at runtime converges on the next event")
    func loweringTheCapConvergesOnTheNextEvent() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.maxEvents = 200
        let service = CachedAnalyticsService(cache: cache, configuration: configuration)

        for index in 0 ..< 200 {
            await service.trackEvent("event-\(index)", duration: .seconds(1), metadata: [:])
        }

        configuration.maxEvents = 10
        await service.updateConfiguration(configuration)
        await service.trackEvent("after-lowering", duration: .seconds(1), metadata: [:])

        // A 10% batch of the NEW cap is 5 events, which would leave the buffer
        // sitting near 200 for a long time. Settings apply through
        // updateConfiguration at runtime, which Python never does.
        let events: [AnalyticsEvent]? = await cache.get(key: CachedAnalyticsService.eventsCacheKey)
        let types = try #require(events?.map(\.eventType))
        #expect(types.count <= 10)
        #expect(types.last == "after-lowering")
    }

    @Test("A realistic cap prunes in batches and keeps the window below it")
    func realisticCapPrunesInBatches() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.maxEvents = 50
        let service = CachedAnalyticsService(cache: cache, configuration: configuration)

        for index in 0 ..< 52 {
            await service.trackEvent("event-\(index)", duration: .seconds(1), metadata: [:])
        }

        // At 50 the batch drops max(5, 5) = 5, so the window lands at 46-50
        // rather than pinned to the cap, and the oldest events are the ones gone.
        let events: [AnalyticsEvent]? = await cache.get(key: CachedAnalyticsService.eventsCacheKey)
        let types = try #require(events?.map(\.eventType))
        #expect(types.count == 47)
        #expect(types.first == "event-5")
        #expect(types.last == "event-51")
    }
}
