// CachedAnalyticsService.swift -- local analytics recorder backed by CacheService.

import Core
import Foundation

public struct AnalyticsEvent: Sendable, Codable, Equatable {
    public let eventType: String
    public let timestamp: Date
    public let durationSeconds: Double
    public let durationBucket: String
    public let metadata: [String: String]

    public init(
        eventType: String,
        timestamp: Date,
        durationSeconds: Double,
        durationBucket: String,
        metadata: [String: String]
    ) {
        self.eventType = eventType
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.durationBucket = durationBucket
        self.metadata = metadata
    }
}

public actor CachedAnalyticsService: AnalyticsService {
    public static let eventsCacheKey = "analytics:events"

    private let cache: any CacheService
    private var configuration: AnalyticsConfig
    private let currentDate: @Sendable () -> Date

    public init(
        cache: any CacheService,
        configuration: AnalyticsConfig,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.configuration = configuration
        self.currentDate = currentDate
    }

    public func updateConfiguration(_ configuration: AnalyticsConfig) {
        self.configuration = configuration
    }

    public func trackEvent(
        _ eventType: String,
        duration: Duration,
        metadata: [String: String]
    ) async {
        guard configuration.enabled else { return }

        let durationSeconds = duration.timeInterval
        let event = AnalyticsEvent(
            eventType: eventType,
            timestamp: currentDate(),
            durationSeconds: durationSeconds,
            durationBucket: durationBucket(for: durationSeconds),
            metadata: metadata
        )
        await append(event)
    }

    public func trackError(_ eventType: String, error: any Error) async {
        guard configuration.enabled else { return }

        await trackEvent(
            "\(eventType).error",
            duration: .seconds(0),
            metadata: ["error": error.localizedDescription]
        )
    }

    private func append(_ event: AnalyticsEvent) async {
        var events: [AnalyticsEvent] = await cache.get(key: Self.eventsCacheKey) ?? []

        // Python parity (_record_function_call, analytics.py:305-309): prune
        // BEFORE recording, drop a batch of 10% (at least 5) rather than the
        // exact overflow, and treat a non-positive cap as "no limit".
        // `max(1, maxEvents)` inverted that last one — a user setting 0 to
        // disable the cap was left holding a single event.
        let maxEvents = configuration.maxEvents
        if maxEvents > 0, events.count >= maxEvents {
            // Python's batch, plus whatever it takes to actually fit under the
            // cap. Python only ever sets max_events at construction, so a batch
            // of 10% always sufficed there; `updateConfiguration` can lower the
            // cap here, and 10% of the NEW cap would leave the old buffer
            // hovering thousands of events above it.
            let batch = max(5, maxEvents / 10)
            let toFitNewEvent = events.count - maxEvents + 1
            events.removeFirst(min(max(batch, toFitNewEvent), events.count))
        }

        events.append(event)
        await cache.set(key: Self.eventsCacheKey, value: events, ttl: nil)
    }

    private func durationBucket(for seconds: Double) -> String {
        let thresholds = configuration.durationThresholds
        if seconds <= thresholds.shortMax {
            return "short"
        }
        if seconds <= thresholds.mediumMax {
            return "medium"
        }
        if seconds <= thresholds.longMax {
            return "long"
        }
        return "very_long"
    }
}
