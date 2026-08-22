import Foundation
import GRDB
import Testing
@testable import Core
@testable import Services

@Suite("Analytics event store")
struct AnalyticsStoreTests {
    @Test("Events round-trip in stable order and filter by session")
    func roundTrip() async throws {
        let store = try await makeStore()
        let firstSession = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondSession = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let timestamp = Date(timeIntervalSince1970: 100)
        let first = event(idSuffix: 1, sessionID: firstSession, timestamp: timestamp)
        let second = event(idSuffix: 2, sessionID: secondSession, timestamp: timestamp)
        let retention = AnalyticsRetentionPolicy(maxEvents: 100, cutoff: .distantPast)

        try await store.append(second, retention: retention)
        try await store.append(first, retention: retention)

        #expect(try await store.events(since: nil, sessionID: nil) == [first, second])
        #expect(try await store.events(since: nil, sessionID: firstSession) == [first])
        #expect(try await store.events(since: timestamp.addingTimeInterval(1), sessionID: nil).isEmpty)
    }

    @Test("Append prunes expired and oldest overflow rows")
    func pruning() async throws {
        let store = try await makeStore()
        let sessionID = UUID()
        let events = [
            event(idSuffix: 1, sessionID: sessionID, timestamp: Date(timeIntervalSince1970: 10)),
            event(idSuffix: 2, sessionID: sessionID, timestamp: Date(timeIntervalSince1970: 20)),
            event(idSuffix: 3, sessionID: sessionID, timestamp: Date(timeIntervalSince1970: 30)),
        ]

        try await store.append(
            events[0],
            retention: AnalyticsRetentionPolicy(maxEvents: 2, cutoff: Date(timeIntervalSince1970: 15))
        )
        try await store.append(
            events[1],
            retention: AnalyticsRetentionPolicy(maxEvents: 2, cutoff: Date(timeIntervalSince1970: 15))
        )
        try await store.append(
            events[2],
            retention: AnalyticsRetentionPolicy(maxEvents: 2, cutoff: Date(timeIntervalSince1970: 15))
        )

        #expect(try await store.events(since: nil, sessionID: nil) == [events[1], events[2]])
    }

    @Test("A zero event cap keeps every retained row")
    func unlimitedCount() async throws {
        let store = try await makeStore()
        let sessionID = UUID()
        let retention = AnalyticsRetentionPolicy(maxEvents: 0, cutoff: .distantPast)

        for index in 1 ... 5 {
            try await store.append(
                event(idSuffix: index, sessionID: sessionID, timestamp: Date(timeIntervalSince1970: Double(index))),
                retention: retention
            )
        }

        #expect(try await store.events(since: nil, sessionID: nil).count == 5)
    }

    @Test("A positive event cap removes the oldest rows")
    func countLimit() async throws {
        let store = try await makeStore()
        let sessionID = UUID()
        let retention = AnalyticsRetentionPolicy(maxEvents: 2, cutoff: .distantPast)
        let events = (1 ... 3).map { index in
            event(
                idSuffix: index,
                sessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }

        for event in events {
            try await store.append(event, retention: retention)
        }

        #expect(try await store.events(since: nil, sessionID: nil) == [events[1], events[2]])
    }

    @Test("Events survive reopening the shared database")
    func relaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("analytics.db")
        let stored = event(idSuffix: 1, sessionID: UUID(), timestamp: Date(timeIntervalSince1970: 100))

        do {
            let store = try GRDBCacheService(databasePath: databaseURL.path)
            try await store.initialize()
            try await store.append(
                stored,
                retention: AnalyticsRetentionPolicy(maxEvents: 100, cutoff: .distantPast)
            )
        }

        let relaunched = try GRDBCacheService(databasePath: databaseURL.path)
        try await relaunched.initialize()
        #expect(try await relaunched.events(since: nil, sessionID: nil) == [stored])
    }

    @Test("Invalid durations fail before persistence")
    func invalidDuration() async throws {
        let store = try await makeStore()
        let invalid = StoredAnalyticsEvent(
            id: UUID(),
            sessionID: UUID(),
            operationValue: AnalyticsOperation.libraryLoad.rawValue,
            startedAt: .now,
            durationSeconds: -.infinity,
            outcome: .failed
        )

        await #expect(throws: AnalyticsStoreError.invalidDuration) {
            try await store.append(
                invalid,
                retention: AnalyticsRetentionPolicy(maxEvents: 100, cutoff: .distantPast)
            )
        }
        #expect(try await store.events(since: nil, sessionID: nil).isEmpty)
    }

    @Test("Legacy cache events migrate once and preserve outcome")
    func legacyMigration() async throws {
        let database = try DatabaseQueue()
        let legacy = [
            LegacyEventFixture(
                eventType: "expired.operation",
                timestamp: Date(timeIntervalSince1970: 1),
                durationSeconds: 1,
                durationBucket: "short",
                metadata: [:]
            ),
            LegacyEventFixture(
                eventType: "library.load",
                timestamp: Date(timeIntervalSince1970: 10),
                durationSeconds: 2,
                durationBucket: "short",
                metadata: [:]
            ),
            LegacyEventFixture(
                eventType: "library.load.error",
                timestamp: Date(timeIntervalSince1970: 20),
                durationSeconds: 0,
                durationBucket: "short",
                metadata: ["error": "private value"]
            ),
        ]
        var migrator = DatabaseMigrator()
        GRDBMigrations.registerMigrations(&migrator)
        try migrator.migrate(database, upTo: "v2_add_generic_access_order")
        try await database.write { database in
            try GenericCacheRow(
                key: AnalyticsLegacy.eventsCacheKey,
                value: JSONEncoder().encode(legacy),
                ttl: nil,
                timestamp: .now,
                accessOrder: 1
            ).insert(database)
        }

        let store = GRDBCacheService(dbWriter: database)
        try await store.initialize()

        let retention = AnalyticsRetentionPolicy(maxEvents: 2, cutoff: Date(timeIntervalSince1970: 5))
        try await store.migrateLegacyAnalytics(retention: retention)
        try await store.migrateLegacyAnalytics(retention: retention)

        let migrated = try await store.events(since: nil, sessionID: AnalyticsLegacy.sessionID)
        let remainingLegacy = try await database.read { database in
            try GenericCacheRow.fetchOne(database, key: AnalyticsLegacy.eventsCacheKey)
        }
        #expect(migrated.map(\.operationValue) == ["library.load", "library.load"])
        #expect(migrated.map(\.outcome) == [.succeeded, .failed])
        #expect(remainingLegacy == nil)
    }

    @Test("Malformed legacy data remains untouched")
    func malformedLegacyData() async throws {
        let database = try DatabaseQueue()
        let store = GRDBCacheService(dbWriter: database)
        try await store.initialize()
        let malformed = Data("not-json".utf8)
        try await database.write { database in
            try GenericCacheRow(
                key: AnalyticsLegacy.eventsCacheKey,
                value: malformed,
                ttl: nil,
                timestamp: .now,
                accessOrder: 1
            ).insert(database)
        }

        do {
            try await store.migrateLegacyAnalytics(
                retention: AnalyticsRetentionPolicy(maxEvents: 100, cutoff: .distantPast)
            )
            Issue.record("Expected malformed legacy analytics to be rejected")
        } catch {
            // The concrete decoder error is not part of the store contract.
        }

        let persisted = try await database.read { database in
            try GenericCacheRow.fetchOne(database, key: AnalyticsLegacy.eventsCacheKey)?.value
        }
        #expect(persisted == malformed)
        #expect(try await store.events(since: nil, sessionID: nil).isEmpty)
    }

    private func makeStore() async throws -> GRDBCacheService {
        let store = try GRDBCacheService.createInMemory()
        try await store.initialize()
        return store
    }

    private func event(
        idSuffix: Int,
        sessionID: UUID,
        timestamp: Date
    ) -> StoredAnalyticsEvent {
        StoredAnalyticsEvent(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(idSuffix))),
            sessionID: sessionID,
            operationValue: AnalyticsOperation.libraryLoad.rawValue,
            startedAt: timestamp,
            durationSeconds: 1,
            outcome: .succeeded
        )
    }
}

private struct LegacyEventFixture: Encodable {
    let eventType: String
    let timestamp: Date
    let durationSeconds: Double
    let durationBucket: String
    let metadata: [String: String]
}
