import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Analytics recorder")
struct AnalyticsRecorderTests {
    @Test("Typed recording persists the process session and current retention")
    func typedRecording() async throws {
        let store = AnalyticsTestStore()
        let sessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.maxEvents = 25
        configuration.retentionDays = 3
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: sessionID,
            currentDate: { now }
        )

        await recorder.record(.libraryLoad, duration: .seconds(2), outcome: .succeeded)

        let stored = await store.appended
        let event = try #require(stored.first?.event)
        let retention = try #require(stored.first?.retention)
        #expect(stored.count == 1)
        #expect(event.sessionID == sessionID)
        #expect(event.operationValue == AnalyticsOperation.libraryLoad.rawValue)
        #expect(event.startedAt == now.addingTimeInterval(-2))
        #expect(event.durationSeconds == 2)
        #expect(event.outcome == .succeeded)
        #expect(retention.maxEvents == 25)
        #expect(retention.cutoff == now.addingTimeInterval(-3 * 86400))
    }

    @Test("Disabled recording performs no clock or store work")
    func disabledFastPath() async {
        let store = AnalyticsTestStore()
        let clock = AnalyticsClockProbe(date: Date(timeIntervalSince1970: 100))
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: AnalyticsConfig(),
            sessionID: UUID(),
            currentDate: { clock.read() }
        )

        await recorder.record(.batchWrite, duration: .seconds(1), outcome: .failed)

        #expect(clock.readCount == 0)
        #expect(await store.appended.isEmpty)
    }

    @Test("Runtime configuration keeps the process session and changes retention")
    func runtimeConfiguration() async {
        let store = AnalyticsTestStore()
        let sessionID = UUID()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.maxEvents = 50
        configuration.retentionDays = 7
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: sessionID,
            currentDate: { Date(timeIntervalSince1970: 1_000_000) }
        )

        await recorder.record(.libraryLoad, duration: .seconds(1), outcome: .succeeded)
        configuration.maxEvents = 5
        configuration.retentionDays = 1
        await recorder.updateConfiguration(configuration)
        await recorder.record(.batchProcess, duration: .seconds(2), outcome: .failed)

        let stored = await store.appended
        #expect(stored.map(\.event.sessionID) == [sessionID, sessionID])
        #expect(stored.map(\.retention.maxEvents) == [50, 5])
        #expect(stored[1].retention.cutoff == Date(timeIntervalSince1970: 913_600))
    }

    @Test("Initialization migrates legacy events once with current retention")
    func initialization() async {
        let store = AnalyticsTestStore()
        let sessionID = UUID()
        var configuration = AnalyticsConfig()
        configuration.maxEvents = 12
        configuration.retentionDays = 2
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: sessionID,
            currentDate: { Date(timeIntervalSince1970: 1_000_000) }
        )

        await recorder.initialize()
        await recorder.initialize()

        let migrations = await store.migrations
        #expect(migrations.count == 1)
        #expect(migrations.first?.retention.maxEvents == 12)
        #expect(migrations.first?.retention.cutoff == Date(timeIntervalSince1970: 827_200))
    }

    @Test("Only successful appends advance the buffered generation")
    func generation() async {
        let store = AnalyticsTestStore()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: UUID(),
            currentDate: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let stream = await recorder.updates()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)

        await store.setAppendFailure(true)
        await recorder.record(.libraryLoad, duration: .seconds(1), outcome: .failed)
        await store.setAppendFailure(false)
        await recorder.record(.libraryLoad, duration: .seconds(1), outcome: .succeeded)

        #expect(await iterator.next() == 1)
    }

    @Test("A subscriber joining after a write receives the current generation")
    func generationAfterWrite() async {
        let store = AnalyticsTestStore()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: UUID(),
            currentDate: { Date(timeIntervalSince1970: 1_000_000) }
        )
        await recorder.record(.libraryLoad, duration: .seconds(1), outcome: .succeeded)

        let stream = await recorder.updates()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == 1)
    }

    @Test("Projection selects the requested durable window")
    func projectionWindow() async {
        let store = AnalyticsTestStore()
        let sessionID = UUID()
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let recorder = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: sessionID
        )
        let now = Date(timeIntervalSince1970: 1_000_000)

        _ = await recorder.projection(for: .currentSession, now: now)
        _ = await recorder.projection(for: .last24Hours, now: now)
        _ = await recorder.projection(for: .last7Days, now: now)

        let queries = await store.queries
        #expect(queries[0].cutoff == nil)
        #expect(queries[0].sessionID == sessionID)
        #expect(queries[1].cutoff == now.addingTimeInterval(-86400))
        #expect(queries[1].sessionID == nil)
        #expect(queries[2].cutoff == now.addingTimeInterval(-7 * 86400))
        #expect(queries[2].sessionID == nil)
    }

    @Test("Disabled projection skips storage and query failures stay available for retry")
    func projectionStates() async {
        let store = AnalyticsTestStore()
        let disabled = AnalyticsRecorder(
            eventStore: store,
            configuration: AnalyticsConfig(),
            sessionID: UUID()
        )

        let disabledProjection = await disabled.projection(for: .last24Hours)
        #expect(disabledProjection.state == .disabled)
        #expect(await store.queries.isEmpty)

        var configuration = AnalyticsConfig()
        configuration.enabled = true
        let enabled = AnalyticsRecorder(
            eventStore: store,
            configuration: configuration,
            sessionID: UUID()
        )
        await store.setQueryFailure(true)

        let unavailableProjection = await enabled.projection(for: .last24Hours)
        #expect(unavailableProjection.state == .unavailable)
        #expect(await store.queries.count == 1)
    }
}

private enum AnalyticsTestError: Error {
    case unavailable
}

private actor AnalyticsTestStore: AnalyticsEventStore {
    struct Append: Sendable {
        let event: StoredAnalyticsEvent
        let retention: AnalyticsRetentionPolicy
    }

    struct Migration: Sendable {
        let retention: AnalyticsRetentionPolicy
    }

    struct Query: Sendable {
        let cutoff: Date?
        let sessionID: UUID?
    }

    private(set) var appended: [Append] = []
    private(set) var migrations: [Migration] = []
    private(set) var queries: [Query] = []
    private var shouldFailAppend = false
    private var shouldFailQuery = false
    var queryEvents: [StoredAnalyticsEvent] = []

    func append(_ event: StoredAnalyticsEvent, retention: AnalyticsRetentionPolicy) throws {
        guard !shouldFailAppend else { throw AnalyticsTestError.unavailable }
        appended.append(Append(event: event, retention: retention))
    }

    func events(since cutoff: Date?, sessionID: UUID?) throws -> [StoredAnalyticsEvent] {
        queries.append(Query(cutoff: cutoff, sessionID: sessionID))
        guard !shouldFailQuery else { throw AnalyticsTestError.unavailable }
        return queryEvents
    }

    func migrateLegacyAnalytics(retention: AnalyticsRetentionPolicy) {
        migrations.append(Migration(retention: retention))
    }

    func setAppendFailure(_ shouldFail: Bool) {
        shouldFailAppend = shouldFail
    }

    func setQueryFailure(_ shouldFail: Bool) {
        shouldFailQuery = shouldFail
    }
}

private final class AnalyticsClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let date: Date
    private var count = 0

    init(date: Date) {
        self.date = date
    }

    var readCount: Int {
        lock.withLock { count }
    }

    func read() -> Date {
        lock.withLock { count += 1 }
        return date
    }
}
