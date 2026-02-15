import Testing
import Foundation
@testable import Services
@testable import Core

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
        let _ = try await makeService()
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

    @Test("Generic cache clear removes all entries")
    func genericCacheClear() async throws {
        let service = try await makeService()

        await service.set(key: "a", value: 1, ttl: nil)
        await service.set(key: "b", value: 2, ttl: nil)
        await service.clear()

        let a: Int? = await service.get(key: "a")
        let b: Int? = await service.get(key: "b")
        #expect(a == nil)
        #expect(b == nil)
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

    // MARK: - syncToDisk

    @Test("syncToDisk completes without error")
    func syncToDisk() async throws {
        let service = try await makeService()
        try await service.syncToDisk()
    }
}
