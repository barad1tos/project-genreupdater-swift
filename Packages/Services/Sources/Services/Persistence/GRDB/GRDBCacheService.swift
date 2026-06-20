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
/// - API responses: caller-configured, 15 minutes by default
/// - Generic cache: caller-specified or configured default
public actor GRDBCacheService: CacheService {
    private let dbWriter: any DatabaseWriter
    private let log = AppLogger.cache
    private let albumYearTTL: TimeInterval
    private let apiResultTTL: TimeInterval
    private let defaultGenericTTL: TimeInterval?
    private let maxGenericEntries: Int
    private let cleanupInterval: TimeInterval
    private var lastGenericCleanupAt = Date.now

    /// Default TTL for album year cache entries (30 days).
    public static let defaultAlbumYearTTL: TimeInterval = 30 * 24 * 3600

    /// Default TTL for API response cache entries (15 minutes).
    public static let defaultAPIResultTTL: TimeInterval = 15 * 60

    /// Default maximum generic cache entries.
    public static let defaultMaxGenericEntries = 10000

    /// Default interval for opportunistic expired-entry cleanup.
    public static let defaultCleanupInterval: TimeInterval = 5 * 60

    /// Create a cache service backed by a database file (uses DatabasePool).
    public init(
        databasePath: String,
        defaultGenericTTL: TimeInterval? = nil,
        apiResultTTL: TimeInterval = GRDBCacheService.defaultAPIResultTTL,
        albumYearTTL: TimeInterval = GRDBCacheService.defaultAlbumYearTTL,
        maxGenericEntries: Int = GRDBCacheService.defaultMaxGenericEntries,
        cleanupInterval: TimeInterval = GRDBCacheService.defaultCleanupInterval
    ) throws {
        dbWriter = try DatabasePool(path: databasePath)
        self.defaultGenericTTL = Self.normalizedTTL(defaultGenericTTL)
        self.apiResultTTL = Self.normalizedTTL(apiResultTTL) ?? Self.defaultAPIResultTTL
        self.albumYearTTL = Self.normalizedTTL(albumYearTTL) ?? Self.defaultAlbumYearTTL
        self.maxGenericEntries = max(1, maxGenericEntries)
        self.cleanupInterval = max(0, cleanupInterval)
    }

    /// Create a cache service with an existing DatabaseWriter (for testing).
    init(
        dbWriter: any DatabaseWriter,
        defaultGenericTTL: TimeInterval? = nil,
        apiResultTTL: TimeInterval = GRDBCacheService.defaultAPIResultTTL,
        albumYearTTL: TimeInterval = GRDBCacheService.defaultAlbumYearTTL,
        maxGenericEntries: Int = GRDBCacheService.defaultMaxGenericEntries,
        cleanupInterval: TimeInterval = GRDBCacheService.defaultCleanupInterval
    ) {
        self.dbWriter = dbWriter
        self.defaultGenericTTL = Self.normalizedTTL(defaultGenericTTL)
        self.apiResultTTL = Self.normalizedTTL(apiResultTTL) ?? Self.defaultAPIResultTTL
        self.albumYearTTL = Self.normalizedTTL(albumYearTTL) ?? Self.defaultAlbumYearTTL
        self.maxGenericEntries = max(1, maxGenericEntries)
        self.cleanupInterval = max(0, cleanupInterval)
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
            let resolvedTTL = ttl ?? defaultGenericTTL
            let now = Date.now
            let shouldCleanup = shouldRunGenericCleanup(at: now)
            try await dbWriter.write { database in
                let row = GenericCacheRow(
                    key: key,
                    value: data,
                    ttl: resolvedTTL,
                    timestamp: .now
                )
                try row.save(database)
                if shouldCleanup {
                    try Self.deleteExpiredGenericRows(in: database)
                }
                try Self.enforceGenericCacheLimit(in: database, maxGenericEntries: maxGenericEntries)
            }
            if shouldCleanup {
                lastGenericCleanupAt = now
            }
        } catch {
            log.error("Cache set failed for key=\(key, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func shouldRunGenericCleanup(at now: Date) -> Bool {
        guard cleanupInterval > 0 else { return false }
        return now.timeIntervalSince(lastGenericCleanupAt) >= cleanupInterval
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
        let signpostState = AppSignpost.cacheOperation.beginInterval("getAlbumYear")
        defer { AppSignpost.cacheOperation.endInterval("getAlbumYear", signpostState) }
        let normalizedKey = Self.normalizedAlbumCacheKey(artist: artist, album: album)

        do {
            return try await dbWriter.read { database -> AlbumCacheEntry? in
                let row = try Self.fetchAlbumYearRow(database, key: normalizedKey)
                    ?? Self.fetchLegacyAlbumYearRow(
                        database,
                        artist: artist,
                        album: album,
                        normalizedKey: normalizedKey
                    )

                guard let row else { return nil }

                let age = Date.now.timeIntervalSince(row.timestamp)
                if age > albumYearTTL {
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
        let normalizedKey = Self.normalizedAlbumCacheKey(artist: artist, album: album)
        do {
            let entry = AlbumCacheEntry(
                artist: normalizedKey.artist,
                album: normalizedKey.album,
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
                try Self.deleteAlbumYearRows(database, artist: artist, album: album)
            }
        } catch {
            log.error("invalidateAlbum failed: \(error, privacy: .public)")
        }
    }

    // MARK: - API Result Cache

    public func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult? {
        let signpostState = AppSignpost.cacheOperation.beginInterval("getCachedAPIResult")
        defer { AppSignpost.cacheOperation.endInterval("getCachedAPIResult", signpostState) }
        let normalizedKey = Self.normalizedAPIResultCacheKey(artist: artist, album: album, source: source)

        do {
            return try await dbWriter.read { database -> CachedAPIResult? in
                let row = try Self.fetchAPIResultRow(database, key: normalizedKey)
                    ?? Self.fetchLegacyAPIResultRow(
                        database,
                        artist: artist,
                        album: album,
                        source: source,
                        normalizedKey: normalizedKey
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
            let normalizedKey = Self.normalizedAPIResultCacheKey(
                artist: result.artist,
                album: result.album,
                source: result.source
            )
            let resultWithTTL = if result.ttl == nil {
                CachedAPIResult(
                    artist: normalizedKey.artist,
                    album: normalizedKey.album,
                    year: result.year,
                    source: normalizedKey.source,
                    timestamp: result.timestamp,
                    ttl: apiResultTTL,
                    metadata: result.metadata
                )
            } else {
                CachedAPIResult(
                    artist: normalizedKey.artist,
                    album: normalizedKey.album,
                    year: result.year,
                    source: normalizedKey.source,
                    timestamp: result.timestamp,
                    ttl: result.ttl,
                    metadata: result.metadata
                )
            }

            try await dbWriter.write { database in
                try CachedAPIRow(from: resultWithTTL).save(database)
            }
        } catch {
            log.error("setCachedAPIResult failed: \(error, privacy: .public)")
        }
    }

    public func invalidateCachedAPIResults(artist: String, album: String) async {
        do {
            try await dbWriter.write { database in
                try Self.deleteAPIResultRows(database, artist: artist, album: album)
            }
        } catch {
            log.error("invalidateCachedAPIResults failed: \(error, privacy: .public)")
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
                    let normalizedKey = Self.normalizedAlbumCacheKey(
                        artist: entry.artist,
                        album: entry.album
                    )
                    let cacheEntry = AlbumCacheEntry(
                        artist: normalizedKey.artist,
                        album: normalizedKey.album,
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
                    try Self.deleteAlbumYearRows(database, artist: artist, album: album)
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

                // SQL-level expiry check avoids loading all rows into memory.
                // GRDB stores Date as "yyyy-MM-dd HH:mm:ss.SSS" strings,
                // so we use strftime to convert to epoch seconds for arithmetic.
                let expiredCount = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM generic_cache
                WHERE ttl IS NOT NULL
                  AND (CAST(strftime('%s', timestamp) AS REAL) + ttl)
                    < CAST(strftime('%s', 'now') AS REAL)
                """) ?? 0

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
    fileprivate struct AlbumCacheKey: Hashable {
        let artist: String
        let album: String
    }

    fileprivate struct APIResultCacheKey: Hashable {
        let artist: String
        let album: String
        let source: String
    }

    fileprivate static func normalizedAlbumCacheKey(artist: String, album: String) -> AlbumCacheKey {
        AlbumCacheKey(
            artist: normalizeForMatching(artist),
            album: normalizeForMatching(album)
        )
    }

    fileprivate static func normalizedAPIResultCacheKey(
        artist: String,
        album: String,
        source: String
    ) -> APIResultCacheKey {
        APIResultCacheKey(
            artist: normalizeForMatching(artist),
            album: normalizeForMatching(album),
            source: normalizeForMatching(source)
        )
    }

    fileprivate static func fetchAlbumYearRow(
        _ database: Database,
        key: AlbumCacheKey
    ) throws -> AlbumYearRow? {
        try AlbumYearRow.fetchOne(
            database,
            sql: "SELECT * FROM album_years WHERE artist = ? AND album = ?",
            arguments: [key.artist, key.album]
        )
    }

    fileprivate static func deleteAlbumYearRows(
        _ database: Database,
        artist: String,
        album: String
    ) throws {
        let normalizedKey = normalizedAlbumCacheKey(artist: artist, album: album)
        try database.execute(
            sql: """
            DELETE FROM album_years
            WHERE (artist = ? AND album = ?)
               OR (LOWER(TRIM(artist)) = ? AND LOWER(TRIM(album)) = ?)
            """,
            arguments: [artist, album, normalizedKey.artist, normalizedKey.album]
        )
    }

    fileprivate static func fetchLegacyAlbumYearRow(
        _ database: Database,
        artist: String,
        album: String,
        normalizedKey: AlbumCacheKey
    ) throws -> AlbumYearRow? {
        let requestedKey = AlbumCacheKey(artist: artist, album: album)
        guard requestedKey != normalizedKey else { return nil }
        return try fetchAlbumYearRow(database, key: requestedKey)
    }

    fileprivate static func fetchAPIResultRow(
        _ database: Database,
        key: APIResultCacheKey
    ) throws -> CachedAPIRow? {
        try CachedAPIRow.fetchOne(
            database,
            sql: "SELECT * FROM api_results WHERE artist = ? AND album = ? AND source = ?",
            arguments: [key.artist, key.album, key.source]
        )
    }

    fileprivate static func fetchLegacyAPIResultRow(
        _ database: Database,
        artist: String,
        album: String,
        source: String,
        normalizedKey: APIResultCacheKey
    ) throws -> CachedAPIRow? {
        let requestedKey = APIResultCacheKey(artist: artist, album: album, source: source)
        guard requestedKey != normalizedKey else { return nil }
        return try fetchAPIResultRow(database, key: requestedKey)
    }

    fileprivate static func deleteAPIResultRows(
        _ database: Database,
        artist: String,
        album: String
    ) throws {
        let normalizedKey = normalizedAlbumCacheKey(artist: artist, album: album)
        try database.execute(
            sql: """
            DELETE FROM api_results
            WHERE (artist = ? AND album = ?)
               OR (LOWER(TRIM(artist)) = ? AND LOWER(TRIM(album)) = ?)
            """,
            arguments: [artist, album, normalizedKey.artist, normalizedKey.album]
        )
    }

    /// Create a cache service with the default Application Support path.
    public static func createDefault(
        defaultGenericTTL: TimeInterval? = nil,
        apiResultTTL: TimeInterval = GRDBCacheService.defaultAPIResultTTL,
        albumYearTTL: TimeInterval = GRDBCacheService.defaultAlbumYearTTL,
        maxGenericEntries: Int = GRDBCacheService.defaultMaxGenericEntries,
        cleanupInterval: TimeInterval = GRDBCacheService.defaultCleanupInterval
    ) throws -> GRDBCacheService {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw GRDBCacheServiceError.applicationSupportNotFound
        }

        let cacheDir = appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let dbPath = cacheDir.appendingPathComponent("api_cache.db").path
        return try GRDBCacheService(
            databasePath: dbPath,
            defaultGenericTTL: defaultGenericTTL,
            apiResultTTL: apiResultTTL,
            albumYearTTL: albumYearTTL,
            maxGenericEntries: maxGenericEntries,
            cleanupInterval: cleanupInterval
        )
    }

    /// Create an in-memory cache service (for testing).
    public static func createInMemory(
        defaultGenericTTL: TimeInterval? = nil,
        apiResultTTL: TimeInterval = GRDBCacheService.defaultAPIResultTTL,
        albumYearTTL: TimeInterval = GRDBCacheService.defaultAlbumYearTTL,
        maxGenericEntries: Int = GRDBCacheService.defaultMaxGenericEntries,
        cleanupInterval: TimeInterval = GRDBCacheService.defaultCleanupInterval
    ) throws -> GRDBCacheService {
        let dbQueue = try DatabaseQueue()
        return GRDBCacheService(
            dbWriter: dbQueue,
            defaultGenericTTL: defaultGenericTTL,
            apiResultTTL: apiResultTTL,
            albumYearTTL: albumYearTTL,
            maxGenericEntries: maxGenericEntries,
            cleanupInterval: cleanupInterval
        )
    }
}

// MARK: - Configuration Helpers

extension GRDBCacheService {
    fileprivate static func normalizedTTL(_ ttl: TimeInterval?) -> TimeInterval? {
        guard let ttl, ttl > 0 else { return nil }
        return ttl
    }

    fileprivate static func enforceGenericCacheLimit(in database: Database, maxGenericEntries: Int) throws {
        let overflowCount = try GenericCacheRow.fetchCount(database) - maxGenericEntries
        guard overflowCount > 0 else { return }

        try database.execute(
            sql: """
            DELETE FROM generic_cache
            WHERE key IN (
                SELECT key FROM generic_cache
                ORDER BY timestamp ASC
                LIMIT ?
            )
            """,
            arguments: [overflowCount]
        )
    }

    fileprivate static func deleteExpiredGenericRows(in database: Database) throws {
        try database.execute(sql: """
        DELETE FROM generic_cache
        WHERE ttl IS NOT NULL
          AND (CAST(strftime('%s', timestamp) AS REAL) + ttl)
            < CAST(strftime('%s', 'now') AS REAL)
        """)
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
