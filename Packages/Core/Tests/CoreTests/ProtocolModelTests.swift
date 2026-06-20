import Foundation
import Testing
@testable import Core

// MARK: - YearResult Tests

@Suite("YearResult — init, defaults, and Codable round-trip")
struct YearResultTests {
    @Test("Default init produces empty result")
    func defaultInit() {
        let result = YearResult()
        #expect(result.year == nil)
        #expect(result.isDefinitive == false)
        #expect(result.confidence == 0)
        #expect(result.rawScore == 0)
        #expect(result.yearScores.isEmpty)
    }

    @Test("Full init preserves all fields")
    func fullInit() {
        let result = YearResult(
            year: 1984,
            isDefinitive: true,
            confidence: 95,
            rawScore: 120,
            yearScores: [1984: 95, 1985: 30]
        )
        #expect(result.year == 1984)
        #expect(result.isDefinitive == true)
        #expect(result.confidence == 95)
        #expect(result.rawScore == 120)
        #expect(result.yearScores.count == 2)
        #expect(result.yearScores[1984] == 95)
    }

    @Test("rawScore defaults to confidence when nil")
    func rawScoreDefaultsToConfidence() {
        let result = YearResult(year: 2000, confidence: 75)
        #expect(result.rawScore == 75)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = YearResult(
            year: 1991,
            isDefinitive: true,
            confidence: 88,
            rawScore: 102,
            yearScores: [1991: 88, 1990: 40]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(YearResult.self, from: data)
        #expect(decoded == original)
    }

    @Test("Equatable conformance works correctly")
    func equatable() {
        let resultA = YearResult(year: 2000, confidence: 80)
        let resultB = YearResult(year: 2000, confidence: 80)
        let resultC = YearResult(year: 2001, confidence: 80)
        #expect(resultA == resultB)
        #expect(resultA != resultC)
    }
}

// MARK: - CachedAPIResult Tests

@Suite("CachedAPIResult — init, expiration, and Codable round-trip")
struct CachedAPIResultTests {
    @Test("isExpired returns false when ttl is nil")
    func notExpiredWhenNoTTL() {
        let result = CachedAPIResult(
            artist: "Artist",
            album: "Album",
            year: 2000,
            source: "MusicBrainz",
            timestamp: Date.now.addingTimeInterval(-86400),
            ttl: nil
        )
        #expect(result.isExpired == false)
    }

    @Test("isExpired returns false when within TTL")
    func notExpiredWithinTTL() {
        let result = CachedAPIResult(
            artist: "Artist",
            album: "Album",
            year: 2000,
            source: "Discogs",
            timestamp: Date.now,
            ttl: 3600
        )
        #expect(result.isExpired == false)
    }

    @Test("isExpired returns true when past TTL")
    func expiredPastTTL() {
        let result = CachedAPIResult(
            artist: "Artist",
            album: "Album",
            year: 2000,
            source: "Discogs",
            timestamp: Date.now.addingTimeInterval(-7200),
            ttl: 3600
        )
        #expect(result.isExpired == true)
    }

    @Test("Codable round-trip preserves all fields including metadata")
    func codableRoundTrip() throws {
        let original = CachedAPIResult(
            artist: "Metallica",
            album: "Master of Puppets",
            year: 1986,
            source: "MusicBrainz",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            ttl: 86400,
            metadata: ["release_group_id": "abc-123"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedAPIResult.self, from: data)
        #expect(decoded == original)
        #expect(decoded.metadata["release_group_id"] == "abc-123")
    }

    @Test("Equatable works for identical results")
    func equatable() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let resultA = CachedAPIResult(
            artist: "A", album: "B", year: 2000,
            source: "X", timestamp: timestamp, ttl: 100
        )
        let resultB = CachedAPIResult(
            artist: "A", album: "B", year: 2000,
            source: "X", timestamp: timestamp, ttl: 100
        )
        #expect(resultA == resultB)
    }
}

// MARK: - AlbumCacheEntry Tests

@Suite("AlbumCacheEntry — init and Codable round-trip")
struct AlbumCacheEntryTests {
    @Test("Init preserves all fields")
    func initPreservesFields() {
        let timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        let entry = AlbumCacheEntry(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: 1984,
            confidence: 90,
            timestamp: timestamp
        )
        #expect(entry.artist == "Iron Maiden")
        #expect(entry.album == "Powerslave")
        #expect(entry.year == 1984)
        #expect(entry.confidence == 90)
        #expect(entry.timestamp == timestamp)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = AlbumCacheEntry(
            artist: "Artist",
            album: "Album",
            year: nil,
            confidence: 0,
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumCacheEntry.self, from: data)
        #expect(decoded == original)
    }

    @Test("nil year encodes and decodes correctly")
    func nilYear() throws {
        let original = AlbumCacheEntry(
            artist: "A", album: "B", year: nil, confidence: 0,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumCacheEntry.self, from: data)
        #expect(decoded.year == nil)
    }
}

// MARK: - LibraryCacheMetadata Tests

@Suite("LibraryCacheMetadata — init and mutability")
struct LibraryCacheMetadataTests {
    @Test("Init preserves all fields")
    func initPreservesFields() {
        let timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        let lastForceScanDate = timestamp.addingTimeInterval(-86400)
        let metadata = LibraryCacheMetadata(
            trackCount: 30000,
            snapshotHash: "abc123",
            timestamp: timestamp,
            libraryModificationDate: timestamp,
            lastForceScanDate: lastForceScanDate
        )
        #expect(metadata.trackCount == 30000)
        #expect(metadata.snapshotHash == "abc123")
        #expect(metadata.lastForceScanDate == lastForceScanDate)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let original = LibraryCacheMetadata(
            trackCount: 100,
            snapshotHash: "hash",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            libraryModificationDate: Date(timeIntervalSince1970: 999_999),
            lastForceScanDate: Date(timeIntervalSince1970: 888_888)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LibraryCacheMetadata.self, from: data)
        #expect(decoded.trackCount == original.trackCount)
        #expect(decoded.snapshotHash == original.snapshotHash)
        #expect(decoded.lastForceScanDate == original.lastForceScanDate)
    }
}

// MARK: - LibraryDeltaCache Tests

@Suite("LibraryDeltaCache — init and set operations")
struct LibraryDeltaCacheTests {
    @Test("Init preserves all fields")
    func initPreservesFields() {
        let delta = LibraryDeltaCache(
            addedIDs: ["a", "b"],
            removedIDs: ["c"],
            modifiedIDs: ["d", "e", "f"],
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(delta.addedIDs.count == 2)
        #expect(delta.removedIDs.count == 1)
        #expect(delta.modifiedIDs.count == 3)
    }

    @Test("Codable round-trip preserves set contents")
    func codableRoundTrip() throws {
        let original = LibraryDeltaCache(
            addedIDs: ["new1", "new2"],
            removedIDs: ["old1"],
            modifiedIDs: [],
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LibraryDeltaCache.self, from: data)
        #expect(decoded.addedIDs == original.addedIDs)
        #expect(decoded.removedIDs == original.removedIDs)
        #expect(decoded.modifiedIDs == original.modifiedIDs)
    }
}

// MARK: - PendingAlbumEntry Tests

@Suite("PendingAlbumEntry — init, defaults, and Identifiable")
struct PendingAlbumEntryTests {
    @Test("Init with defaults")
    func initWithDefaults() {
        let entry = PendingAlbumEntry(
            id: "entry-1",
            artist: "Artist",
            album: "Album",
            reason: "Low confidence"
        )
        #expect(entry.id == "entry-1")
        #expect(entry.attemptCount == 0)
        #expect(entry.recheckInterval == 1_209_600) // 14 days
        #expect(entry.metadata.isEmpty)
    }

    @Test("Init with custom values")
    func initWithCustomValues() {
        let entry = PendingAlbumEntry(
            id: "entry-2",
            artist: "Metallica",
            album: "Ride the Lightning",
            reason: "Year mismatch",
            attemptCount: 3,
            recheckInterval: 604_800,
            metadata: ["source": "discogs"]
        )
        #expect(entry.attemptCount == 3)
        #expect(entry.recheckInterval == 604_800)
        #expect(entry.metadata["source"] == "discogs")
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = PendingAlbumEntry(
            id: "test",
            artist: "A",
            album: "B",
            reason: "R",
            attemptCount: 5,
            lastAttempt: Date(timeIntervalSince1970: 1_700_000_000),
            recheckInterval: 3600,
            metadata: ["key": "value"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingAlbumEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.attemptCount == original.attemptCount)
        #expect(decoded.metadata == original.metadata)
    }
}

// MARK: - RateLimiterStats Tests

@Suite("RateLimiterStats — init")
struct RateLimiterStatsTests {
    @Test("Init preserves all fields")
    func initPreservesFields() {
        let stats = RateLimiterStats(
            totalRequests: 42,
            totalWaitTime: .seconds(10),
            currentTokens: 5
        )
        #expect(stats.totalRequests == 42)
        #expect(stats.totalWaitTime == .seconds(10))
        #expect(stats.currentTokens == 5)
    }
}
