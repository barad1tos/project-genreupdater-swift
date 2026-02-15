// GRDBModels.swift — GRDB row types for API cache tables
// Phase 2A: Persistence Layer

import Foundation
import GRDB
import Core

// MARK: - Cached API Result Row

/// GRDB row type for the `api_results` table.
///
/// Maps to/from `Core.CachedAPIResult` domain type.
struct CachedAPIRow: Codable, FetchableRecord, PersistableRecord, Sendable {
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
        self.artist = result.artist
        self.album = result.album
        self.source = result.source
        self.year = result.year
        self.confidence = 0
        self.timestamp = result.timestamp
        self.ttl = result.ttl
        self.metadata = Self.encodeMetadata(result.metadata)
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
struct AlbumYearRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "album_years"

    var artist: String
    var album: String
    var year: Int?
    var confidence: Int
    var timestamp: Date

    init(from entry: AlbumCacheEntry) {
        self.artist = entry.artist
        self.album = entry.album
        self.year = entry.year
        self.confidence = entry.confidence
        self.timestamp = entry.timestamp
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
struct GenericCacheRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "generic_cache"

    var key: String
    var value: Data
    var ttl: Double?
    var timestamp: Date

    var isExpired: Bool {
        guard let ttl else { return false }
        return Date.now > timestamp.addingTimeInterval(ttl)
    }
}
