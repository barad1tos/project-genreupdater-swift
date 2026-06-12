import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("GRDBCacheService — Phase 2A")
struct GRDBCacheServiceTests {
    /// Create an in-memory GRDBCacheService for testing.
    private func makeService() async throws -> GRDBCacheService {
        let service = try GRDBCacheService.createInMemory()
        try await service.initialize()
        return service
    }

    // MARK: - Migrations

    @Test("Migrations run without error on empty database")
    func migrationsSucceed() async throws {
        _ = try await makeService()
    }

    // MARK: - Generic Cache

    @Test("Generic cache set and get roundtrip")
    func genericCacheRoundtrip() async throws {
        let service = try await makeService()

        await service.set(key: "test_key", value: "hello world", ttl: nil)
        let result: String? = await service.get(key: "test_key")
        #expect(result == "hello world")
    }

    @Test("Generic cache returns nil for missing key")
    func genericCacheMiss() async throws {
        let service = try await makeService()

        let result: String? = await service.get(key: "nonexistent")
        #expect(result == nil)
    }

    @Test("Generic cache invalidate removes entry")
    func genericCacheInvalidate() async throws {
        let service = try await makeService()

        await service.set(key: "to_remove", value: 42, ttl: nil)
        await service.invalidate(key: "to_remove")

        let result: Int? = await service.get(key: "to_remove")
        #expect(result == nil)
    }

    @Test("Generic cache respects TTL expiry")
    func genericCacheTTLExpiry() async throws {
        let service = try await makeService()

        // Set with TTL of -1 second (already expired)
        await service.set(key: "expired", value: "old", ttl: -1)
        let result: String? = await service.get(key: "expired")
        #expect(result == nil)
    }

    @Test("Generic cache uses configured default TTL when none is provided")
    func genericCacheUsesConfiguredDefaultTTL() async throws {
        let service = try GRDBCacheService.createInMemory(defaultGenericTTL: 0.001)
        try await service.initialize()

        await service.set(key: "default_ttl", value: "short", ttl: nil)
        try await Task.sleep(for: .milliseconds(20))

        let result: String? = await service.get(key: "default_ttl")
        #expect(result == nil)
    }

    @Test("Generic cache explicit TTL overrides configured default")
    func genericCacheExplicitTTLOverridesDefault() async throws {
        let service = try GRDBCacheService.createInMemory(defaultGenericTTL: 0.001)
        try await service.initialize()

        await service.set(key: "explicit_ttl", value: "long", ttl: 3600)
        try await Task.sleep(for: .milliseconds(20))

        let result: String? = await service.get(key: "explicit_ttl")
        #expect(result == "long")
    }

    @Test("Generic cache enforces configured entry limit")
    func genericCacheEntryLimit() async throws {
        let service = try GRDBCacheService.createInMemory(maxGenericEntries: 2)
        try await service.initialize()

        await service.set(key: "a", value: 1, ttl: 3600)
        await service.set(key: "b", value: 2, ttl: 3600)
        await service.set(key: "c", value: 3, ttl: 3600)

        let stats = await service.getCacheStatistics()
        #expect(stats.genericCacheCount == 2)
    }

    @Test("Generic cache clear removes all entries")
    func genericCacheClear() async throws {
        let service = try await makeService()

        await service.set(key: "a", value: 1, ttl: nil)
        await service.set(key: "b", value: 2, ttl: nil)
        await service.clear()

        let valueA: Int? = await service.get(key: "a")
        let valueB: Int? = await service.get(key: "b")
        #expect(valueA == nil)
        #expect(valueB == nil)
    }

    // MARK: - Album Year Cache

    @Test("Album year store and retrieve")
    func albumYearRoundtrip() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(artist: "Metallica", album: "Ride the Lightning", year: 1984, confidence: 95)
        let entry = await service.getAlbumYear(artist: "Metallica", album: "Ride the Lightning")

        #expect(entry != nil)
        #expect(entry?.year == 1984)
        #expect(entry?.confidence == 95)
    }

    @Test("Album year returns nil for missing entry")
    func albumYearMiss() async throws {
        let service = try await makeService()

        let entry = await service.getAlbumYear(artist: "Nobody", album: "Nothing")
        #expect(entry == nil)
    }

    @Test("Album year invalidate removes entry")
    func albumYearInvalidate() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(artist: "Test", album: "Album", year: 2020, confidence: 80)
        await service.invalidateAlbum(artist: "Test", album: "Album")

        let entry = await service.getAlbumYear(artist: "Test", album: "Album")
        #expect(entry == nil)
    }

    @Test("Album year upsert updates existing entry")
    func albumYearUpsert() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(artist: "Band", album: "Album", year: 2020, confidence: 50)
        await service.storeAlbumYear(artist: "Band", album: "Album", year: 2021, confidence: 90)

        let entry = await service.getAlbumYear(artist: "Band", album: "Album")
        #expect(entry?.year == 2021)
        #expect(entry?.confidence == 90)
    }

    // MARK: - API Result Cache

    @Test("API result store and retrieve")
    func apiResultRoundtrip() async throws {
        let service = try await makeService()

        let result = CachedAPIResult(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: 1984,
            source: "musicbrainz",
            timestamp: .now,
            ttl: 3600,
            metadata: ["release_group_id": "abc123"]
        )

        await service.setCachedAPIResult(result)
        let cached = await service.getCachedAPIResult(
            artist: "Iron Maiden",
            album: "Powerslave",
            source: "musicbrainz"
        )

        #expect(cached != nil)
        #expect(cached?.year == 1984)
        #expect(cached?.metadata["release_group_id"] == "abc123")
    }

    @Test("API result returns nil for expired entry")
    func apiResultExpired() async throws {
        let service = try await makeService()

        let result = CachedAPIResult(
            artist: "Test",
            album: "Album",
            year: 2020,
            source: "discogs",
            timestamp: Date.now.addingTimeInterval(-7200),
            ttl: 3600
        )

        await service.setCachedAPIResult(result)
        let cached = await service.getCachedAPIResult(artist: "Test", album: "Album", source: "discogs")
        #expect(cached == nil)
    }

    @Test("API result applies default TTL when none provided")
    func apiResultDefaultTTL() async throws {
        let service = try await makeService()

        let result = CachedAPIResult(
            artist: "Test",
            album: "Album",
            year: 2020,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        )

        await service.setCachedAPIResult(result)

        // Should be retrievable since it was just set with default TTL
        let cached = await service.getCachedAPIResult(artist: "Test", album: "Album", source: "musicbrainz")
        #expect(cached != nil)
    }

    @Test("API result default TTL is configurable")
    func apiResultConfigurableDefaultTTL() async throws {
        let service = try GRDBCacheService.createInMemory(apiResultTTL: 0.001)
        try await service.initialize()

        let result = CachedAPIResult(
            artist: "Test",
            album: "Album",
            year: 2020,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        )

        await service.setCachedAPIResult(result)
        try await Task.sleep(for: .milliseconds(20))

        let cached = await service.getCachedAPIResult(artist: "Test", album: "Album", source: "musicbrainz")
        #expect(cached == nil)
    }

    @Test("API result returns nil for wrong source")
    func apiResultWrongSource() async throws {
        let service = try await makeService()

        let result = CachedAPIResult(
            artist: "Test",
            album: "Album",
            year: 2020,
            source: "musicbrainz",
            timestamp: .now,
            ttl: 3600
        )

        await service.setCachedAPIResult(result)
        let cached = await service.getCachedAPIResult(artist: "Test", album: "Album", source: "discogs")
        #expect(cached == nil)
    }

    // MARK: - Bulk Operations

    @Test("Bulk store album years stores all entries in one transaction")
    func bulkStoreAlbumYears() async throws {
        let service = try await makeService()

        await service.bulkStoreAlbumYears([
            BulkAlbumYearEntry(artist: "Metallica", album: "Master of Puppets", year: 1986, confidence: 95),
            BulkAlbumYearEntry(artist: "Metallica", album: "Ride the Lightning", year: 1984, confidence: 90),
            BulkAlbumYearEntry(artist: "Iron Maiden", album: "Powerslave", year: 1984, confidence: 85),
        ])

        let entry1 = await service.getAlbumYear(artist: "Metallica", album: "Master of Puppets")
        let entry2 = await service.getAlbumYear(artist: "Metallica", album: "Ride the Lightning")
        let entry3 = await service.getAlbumYear(artist: "Iron Maiden", album: "Powerslave")

        #expect(entry1?.year == 1986)
        #expect(entry1?.confidence == 95)
        #expect(entry2?.year == 1984)
        #expect(entry3?.year == 1984)
        #expect(entry3?.confidence == 85)
    }

    @Test("Bulk invalidate removes all specified entries")
    func bulkInvalidateAlbumYears() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(artist: "A", album: "X", year: 2020, confidence: 80)
        await service.storeAlbumYear(artist: "B", album: "Y", year: 2021, confidence: 80)

        await service.bulkInvalidateAlbums([
            (artist: "A", album: "X"),
            (artist: "B", album: "Y"),
        ])

        let entryA = await service.getAlbumYear(artist: "A", album: "X")
        let entryB = await service.getAlbumYear(artist: "B", album: "Y")
        #expect(entryA == nil)
        #expect(entryB == nil)
    }

    // MARK: - Cache Statistics

    @Test("Cache statistics track entry counts across tables")
    func cacheStatisticsEntryCounts() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(artist: "A", album: "X", year: 2020, confidence: 80)
        await service.set(key: "k1", value: "v1", ttl: nil)

        let apiResult = CachedAPIResult(
            artist: "Test",
            album: "Album",
            year: 2020,
            source: "musicbrainz",
            timestamp: .now,
            ttl: 3600
        )
        await service.setCachedAPIResult(apiResult)

        let stats = await service.getCacheStatistics()
        #expect(stats.albumYearCount == 1)
        #expect(stats.genericCacheCount == 1)
        #expect(stats.apiResultCount == 1)
    }

    @Test("Cache statistics report expired generic cache entries")
    func cacheStatisticsExpiredEntries() async throws {
        let service = try await makeService()

        // Expired entry (TTL of -1 second — already past)
        await service.set(key: "expired", value: "old", ttl: -1)
        // Valid entry with future TTL
        await service.set(key: "valid", value: "new", ttl: 3600)
        // Entry with no TTL (never expires)
        await service.set(key: "permanent", value: "forever", ttl: nil)

        let stats = await service.getCacheStatistics()
        #expect(stats.genericCacheCount == 3)
        #expect(stats.expiredCount == 1)
    }

    @Test("Generic cache cleanup removes expired entries after configured interval")
    func genericCacheCleanupUsesConfiguredInterval() async throws {
        let service = try GRDBCacheService.createInMemory(cleanupInterval: 0.001)
        try await service.initialize()

        await service.set(key: "expired", value: "old", ttl: -1)
        try await Task.sleep(for: .milliseconds(2))
        await service.set(key: "valid", value: "new", ttl: 3600)

        let stats = await service.getCacheStatistics()
        #expect(stats.genericCacheCount == 1)
        #expect(stats.expiredCount == 0)
    }

    // MARK: - syncToDisk

    @Test("syncToDisk completes without error")
    func syncToDisk() async throws {
        let service = try await makeService()
        try await service.syncToDisk()
    }
}
