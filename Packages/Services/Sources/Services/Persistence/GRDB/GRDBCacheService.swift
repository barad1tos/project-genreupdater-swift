// GRDBCacheService.swift — GRDB-backed persistent API cache
// Phase 2A: Persistence Layer

import Core
import Foundation
import GRDB
import OSLog

/// Persistent cache for API responses and album year data.
///
/// Uses GRDB's `DatabasePool` for concurrent reads and serialized writes.
/// Database file lives in Application Support/GenreUpdater/api_cache.db.
///
/// TTL defaults:
/// - Album years: 30 days
/// - API responses: 15 minutes
/// - Generic cache: caller-specified or no expiry
public actor GRDBCacheService: CacheService {
    private let dbWriter: any DatabaseWriter
    private let log = AppLogger.cache

    /// Default TTL for album year cache entries (30 days).
    static let albumYearTTL: TimeInterval = 30 * 24 * 3600

    /// Default TTL for API response cache entries (15 minutes).
    static let apiResultTTL: TimeInterval = 15 * 60

    /// Create a cache service backed by a database file (uses DatabasePool).
    ///
    /// - Parameter databasePath: Path to the SQLite database file.
    ///   Created automatically if it doesn't exist.
    public init(databasePath: String) throws {
        dbWriter = try DatabasePool(path: databasePath)
    }

    /// Create a cache service with an existing DatabaseWriter (for testing).
    ///
    /// Pass `DatabaseQueue()` for in-memory tests (DatabasePool requires WAL
    /// which doesn't support `:memory:`).
    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Initialization

    public func initialize() async throws {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        GRDBMigrations.registerMigrations(&migrator)
        try migrator.migrate(dbWriter)
        log.info("GRDB cache initialized")
    }

    // MARK: - Generic Key-Value Cache

    public func get<T: Codable & Sendable>(key: String) async -> T? {
        do {
            return try await dbWriter.read { database in
                guard let row = try GenericCacheRow.fetchOne(
                    database,
                    key: key
                ) else {
                    return nil
                }

                if row.isExpired {
                    return nil
                }

                return try JSONDecoder().decode(T.self, from: row.value)
            }
        } catch {
            log.error("Cache get failed for key=\(key, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    public func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async {
        do {
            let data = try JSONEncoder().encode(value)
            try await dbWriter.write { database in
                let row = GenericCacheRow(
                    key: key,
                    value: data,
                    ttl: ttl,
                    timestamp: .now
                )
                try row.save(database)
            }
        } catch {
            log.error("Cache set failed for key=\(key, privacy: .public): \(error, privacy: .public)")
        }
    }

    public func invalidate(key: String) async {
        do {
            try await dbWriter.write { database in
                _ = try GenericCacheRow.deleteOne(database, key: key)
            }
        } catch {
            log.error("Cache invalidate failed for key=\(key, privacy: .public): \(error, privacy: .public)")
        }
    }

    public func clear() async {
        do {
            try await dbWriter.write { database in
                try GenericCacheRow.deleteAll(database)
                try CachedAPIRow.deleteAll(database)
                try AlbumYearRow.deleteAll(database)
            }
            log.info("Cache cleared")
        } catch {
            log.error("Cache clear failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Album Year Cache

    public func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry? {
        do {
            return try await dbWriter.read { database -> AlbumCacheEntry? in
                let row = try AlbumYearRow.fetchOne(
                    database,
                    sql: "SELECT * FROM album_years WHERE artist = ? AND album = ?",
                    arguments: [artist, album]
                )

                guard let row else { return nil }

                let age = Date.now.timeIntervalSince(row.timestamp)
                if age > GRDBCacheService.albumYearTTL {
                    return nil
                }

                return row.toAlbumCacheEntry()
            }
        } catch {
            log.error("getAlbumYear failed: \(error, privacy: .public)")
            return nil
        }
    }

    public func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async {
        do {
            let entry = AlbumCacheEntry(
                artist: artist,
                album: album,
                year: year,
                confidence: confidence,
                timestamp: .now
            )
            try await dbWriter.write { database in
                try AlbumYearRow(from: entry).save(database)
            }
        } catch {
            log.error("storeAlbumYear failed: \(error, privacy: .public)")
        }
    }

    public func invalidateAlbum(artist: String, album: String) async {
        do {
            try await dbWriter.write { database in
                try database.execute(
                    sql: "DELETE FROM album_years WHERE artist = ? AND album = ?",
                    arguments: [artist, album]
                )
            }
        } catch {
            log.error("invalidateAlbum failed: \(error, privacy: .public)")
        }
    }

    // MARK: - API Result Cache

    public func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult? {
        do {
            return try await dbWriter.read { database -> CachedAPIResult? in
                let row = try CachedAPIRow.fetchOne(
                    database,
                    sql: "SELECT * FROM api_results WHERE artist = ? AND album = ? AND source = ?",
                    arguments: [artist, album, source]
                )

                guard let row else { return nil }

                let result = row.toCachedAPIResult()
                if result.isExpired {
                    return nil
                }

                return result
            }
        } catch {
            log.error("getCachedAPIResult failed: \(error, privacy: .public)")
            return nil
        }
    }

    public func setCachedAPIResult(_ result: CachedAPIResult) async {
        do {
            let resultWithTTL: CachedAPIResult = if result.ttl == nil {
                CachedAPIResult(
                    artist: result.artist,
                    album: result.album,
                    year: result.year,
                    source: result.source,
                    timestamp: result.timestamp,
                    ttl: GRDBCacheService.apiResultTTL,
                    metadata: result.metadata
                )
            } else {
                result
            }

            try await dbWriter.write { database in
                try CachedAPIRow(from: resultWithTTL).save(database)
            }
        } catch {
            log.error("setCachedAPIResult failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Bulk Operations

    /// Store multiple album year entries in a single write transaction.
    ///
    /// More efficient than calling `storeAlbumYear` in a loop because all
    /// inserts share a single SQLite transaction (one fsync instead of N).
    ///
    /// - Parameter entries: Album year entries to store.
    public func bulkStoreAlbumYears(_ entries: [BulkAlbumYearEntry]) async {
        do {
            try await dbWriter.write { database in
                for entry in entries {
                    let cacheEntry = AlbumCacheEntry(
                        artist: entry.artist,
                        album: entry.album,
                        year: entry.year,
                        confidence: entry.confidence,
                        timestamp: .now
                    )
                    try AlbumYearRow(from: cacheEntry).save(database)
                }
            }
            log.info("Bulk stored \(entries.count, privacy: .public) album years")
        } catch {
            log.error("bulkStoreAlbumYears failed: \(error, privacy: .public)")
        }
    }

    /// Delete multiple album year entries in a single write transaction.
    ///
    /// - Parameter albums: Tuples of (artist, album) identifying entries to remove.
    public func bulkInvalidateAlbums(
        _ albums: [(artist: String, album: String)]
    ) async {
        do {
            try await dbWriter.write { database in
                for (artist, album) in albums {
                    try database.execute(
                        sql: "DELETE FROM album_years WHERE artist = ? AND album = ?",
                        arguments: [artist, album]
                    )
                }
            }
        } catch {
            log.error("bulkInvalidateAlbums failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Cache Statistics

    /// Aggregate statistics about cache contents.
    ///
    /// Counts entries in each table and identifies expired generic cache rows
    /// (those with a non-nil TTL whose timestamp + TTL is in the past).
    ///
    /// - Returns: A `CacheStatistics` snapshot. Returns zeroes on database error.
    public func getCacheStatistics() async -> CacheStatistics {
        do {
            return try await dbWriter.read { database in
                let albumYearCount = try AlbumYearRow.fetchCount(database)
                let apiResultCount = try CachedAPIRow.fetchCount(database)
                let genericCacheCount = try GenericCacheRow.fetchCount(database)

                let expiredCount = try GenericCacheRow
                    .filter(Column("ttl") != nil)
                    .fetchAll(database)
                    .filter(\.isExpired)
                    .count

                return CacheStatistics(
                    albumYearCount: albumYearCount,
                    apiResultCount: apiResultCount,
                    genericCacheCount: genericCacheCount,
                    expiredCount: expiredCount
                )
            }
        } catch {
            log.error("getCacheStatistics failed: \(error, privacy: .public)")
            return CacheStatistics(
                albumYearCount: 0,
                apiResultCount: 0,
                genericCacheCount: 0,
                expiredCount: 0
            )
        }
    }

    // MARK: - Persistence

    public func syncToDisk() async throws {
        // GRDB auto-persists via WAL — this is a no-op
    }
}

// MARK: - Errors

/// Errors specific to GRDBCacheService initialization.
public enum GRDBCacheServiceError: Error {
    case applicationSupportNotFound
}

// MARK: - Factory

extension GRDBCacheService {
    /// Create a cache service with the default Application Support path.
    public static func createDefault() throws -> GRDBCacheService {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw GRDBCacheServiceError.applicationSupportNotFound
        }

        let cacheDir = appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let dbPath = cacheDir.appendingPathComponent("api_cache.db").path
        return try GRDBCacheService(databasePath: dbPath)
    }

    /// Create an in-memory cache service (for testing).
    public static func createInMemory() throws -> GRDBCacheService {
        let dbQueue = try DatabaseQueue()
        return GRDBCacheService(dbWriter: dbQueue)
    }
}

// MARK: - Cache Statistics

/// Aggregate snapshot of cache contents.
///
/// All counts reflect the state at the time `getCacheStatistics()` was called.
/// `expiredCount` only tracks generic cache entries (album years and API results
/// use age-based TTL checks at read time instead).
public struct CacheStatistics: Sendable {
    public let albumYearCount: Int
    public let apiResultCount: Int
    public let genericCacheCount: Int
    public let expiredCount: Int
}

// MARK: - Bulk Album Year Entry

/// Input for `bulkStoreAlbumYears` — avoids a 4-member tuple (SwiftLint large_tuple).
public struct BulkAlbumYearEntry: Sendable {
    public let artist: String
    public let album: String
    public let year: Int
    public let confidence: Int

    public init(artist: String, album: String, year: Int, confidence: Int) {
        self.artist = artist
        self.album = album
        self.year = year
        self.confidence = confidence
    }
}
