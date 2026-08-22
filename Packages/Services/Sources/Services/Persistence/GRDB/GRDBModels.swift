// GRDBModels.swift — GRDB row types for API cache tables
// Phase 2A: Persistence Layer

import Core
import Foundation
import GRDB

// MARK: - Cached API Result Row

/// GRDB row type for the `api_results` table.
///
/// Maps to/from `Core.CachedAPIResult` domain type.
struct CachedAPIRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "api_results"

    var artist: String
    var album: String
    var source: String
    var year: Int?
    var confidence: Int
    var timestamp: Date
    var ttl: Double?
    var metadata: String

    init(from result: CachedAPIResult) {
        artist = result.artist
        album = result.album
        source = result.source
        year = result.year
        confidence = 0
        timestamp = result.timestamp
        ttl = result.ttl
        metadata = Self.encodeMetadata(result.metadata)
    }

    func toCachedAPIResult() -> CachedAPIResult {
        CachedAPIResult(
            artist: artist,
            album: album,
            year: year,
            source: source,
            timestamp: timestamp,
            ttl: ttl,
            metadata: Self.decodeMetadata(metadata)
        )
    }

    private static func encodeMetadata(_ dict: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(dict) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeMetadata(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }
}

// MARK: - Album Year Row

/// GRDB row type for the `album_years` table.
///
/// Maps to/from `Core.AlbumCacheEntry` domain type.
struct AlbumYearRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album_years"

    var artist: String
    var album: String
    var year: Int?
    var confidence: Int
    var timestamp: Date

    init(from entry: AlbumCacheEntry) {
        artist = entry.artist
        album = entry.album
        year = entry.year
        confidence = entry.confidence
        timestamp = entry.timestamp
    }

    func toAlbumCacheEntry() -> AlbumCacheEntry {
        AlbumCacheEntry(
            artist: artist,
            album: album,
            year: year,
            confidence: confidence,
            timestamp: timestamp
        )
    }
}

// MARK: - Generic Cache Row

/// GRDB row type for the `generic_cache` table.
///
/// Stores arbitrary Codable values as JSON blobs with optional TTL.
struct GenericCacheRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "generic_cache"

    var key: String
    var value: Data
    var ttl: Double?
    var timestamp: Date
    var accessOrder: Int64 = 0

    var isExpired: Bool {
        guard let ttl else { return false }
        return Date.now > timestamp.addingTimeInterval(ttl)
    }
}

// MARK: - Analytics Event Row

struct AnalyticsEventRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "analytics_events"

    var id: String
    var sessionID: String
    var operation: String
    var startedAt: Date
    var durationSeconds: Double
    var outcome: String

    init(from event: StoredAnalyticsEvent) {
        id = event.id.uuidString
        sessionID = event.sessionID.uuidString
        operation = event.operationValue
        startedAt = event.startedAt
        durationSeconds = event.durationSeconds
        outcome = event.outcome.rawValue
    }

    func toStoredEvent() throws -> StoredAnalyticsEvent {
        guard let id = UUID(uuidString: id) else {
            throw AnalyticsStoreError.invalidIdentifier(id)
        }
        guard let sessionID = UUID(uuidString: sessionID) else {
            throw AnalyticsStoreError.invalidIdentifier(sessionID)
        }
        guard let outcome = AnalyticsOutcome(rawValue: outcome) else {
            throw AnalyticsStoreError.invalidOutcome(outcome)
        }

        return StoredAnalyticsEvent(
            id: id,
            sessionID: sessionID,
            operationValue: operation,
            startedAt: startedAt,
            durationSeconds: durationSeconds,
            outcome: outcome
        )
    }
}
