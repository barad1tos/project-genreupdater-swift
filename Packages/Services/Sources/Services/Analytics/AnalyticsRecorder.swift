import Core
import Foundation

/// Records privacy-safe operation timing and projects durable local history.
public actor AnalyticsRecorder: AnalyticsService {
    private let eventStore: any AnalyticsEventStore
    private let sessionID: UUID
    private let currentDate: @Sendable () -> Date
    private let log = AppLogger.make(category: "analytics")
    private var configuration: AnalyticsConfig
    private var generation: UInt64 = 0
    private var continuations: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var isInitialized = false

    public init(
        store: GRDBCacheService,
        configuration: AnalyticsConfig,
        sessionID: UUID = UUID(),
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        eventStore = store
        self.configuration = configuration
        self.sessionID = sessionID
        self.currentDate = currentDate
    }

    init(
        eventStore: any AnalyticsEventStore,
        configuration: AnalyticsConfig,
        sessionID: UUID,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.eventStore = eventStore
        self.configuration = configuration
        self.sessionID = sessionID
        self.currentDate = currentDate
    }

    /// Migrates the legacy analytics blob once without blocking new recording on failure.
    public func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        let now = currentDate()
        do {
            try await eventStore.migrateLegacyAnalytics(
                retention: retentionPolicy(now: now)
            )
        } catch {
            log.error("Legacy analytics migration failed")
        }
    }

    public func updateConfiguration(_ configuration: AnalyticsConfig) {
        self.configuration = configuration
        advanceGeneration()
    }

    public func record(
        _ operation: AnalyticsOperation,
        duration: Duration,
        outcome: AnalyticsOutcome
    ) async {
        guard configuration.enabled else { return }
        let now = currentDate()
        let durationSeconds = duration.timeInterval
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            log.error("Analytics event duration is invalid")
            return
        }
        let event = StoredAnalyticsEvent(
            id: UUID(),
            sessionID: sessionID,
            operationValue: operation.rawValue,
            startedAt: now.addingTimeInterval(-durationSeconds),
            durationSeconds: durationSeconds,
            outcome: outcome
        )

        do {
            try await eventStore.append(event, retention: retentionPolicy(now: now))
            advanceGeneration()
        } catch {
            log.error("Analytics event persistence failed")
        }
    }

    /// Builds the selected report without exposing durable event rows.
    public func projection(
        for window: AnalyticsReportWindow,
        now: Date = .now
    ) async -> AnalyticsProjection {
        guard configuration.enabled else {
            return .empty(state: .disabled, window: window, isRecordingEnabled: false)
        }
        let query = window.query(now: now, sessionID: sessionID)
        do {
            let events = try await eventStore.events(since: query.cutoff, sessionID: query.sessionID)
            return AnalyticsBuilder.build(events: events, window: window, configuration: configuration)
        } catch {
            log.error("Analytics report query failed")
            return .unavailable(window: window, isRecordingEnabled: true)
        }
    }

    /// Emits a newest-only generation after successful writes or configuration changes.
    public func updates() -> AsyncStream<UInt64> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[subscriptionID] = continuation
        continuation.yield(generation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id: subscriptionID)
            }
        }
        return stream
    }

    private func retentionPolicy(now: Date) -> AnalyticsRetentionPolicy {
        AnalyticsRetentionPolicy(
            maxEvents: configuration.maxEvents,
            cutoff: now.addingTimeInterval(-TimeInterval(configuration.retentionDays) * 86400)
        )
    }

    private func advanceGeneration() {
        generation &+= 1
        let terminated = continuations.compactMap { id, continuation in
            if case .terminated = continuation.yield(generation) {
                return id
            }
            return nil
        }
        for id in terminated {
            continuations[id] = nil
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}
