import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("GRDBModels — row type mapping and expiry")
struct GRDBModelsTests {
    // MARK: - CachedAPIRow

    @Test("init(from:) maps all fields from CachedAPIResult")
    func cachedAPIRowInitMapsAllFields() {
        let timestamp = Date.now
        let result = CachedAPIResult(
            artist: "Beatles",
            album: "Abbey Road",
            year: 1969,
            source: "musicbrainz",
            timestamp: timestamp,
            ttl: 900,
            metadata: ["key": "val"]
        )

        let row = CachedAPIRow(from: result)

        #expect(row.artist == "Beatles")
        #expect(row.album == "Abbey Road")
        #expect(row.year == 1969)
        #expect(row.source == "musicbrainz")
        #expect(row.timestamp == timestamp)
        #expect(row.ttl == 900)
        #expect(row.confidence == 0)
    }

    @Test("toCachedAPIResult() round-trips all fields")
    func cachedAPIRowRoundTrip() {
        let timestamp = Date.now
        let original = CachedAPIResult(
            artist: "Beatles",
            album: "Abbey Road",
            year: 1969,
            source: "musicbrainz",
            timestamp: timestamp,
            ttl: 900,
            metadata: ["key": "val"]
        )

        let roundTripped = CachedAPIRow(from: original).toCachedAPIResult()

        #expect(roundTripped.artist == original.artist)
        #expect(roundTripped.album == original.album)
        #expect(roundTripped.year == original.year)
        #expect(roundTripped.source == original.source)
        #expect(roundTripped.timestamp == original.timestamp)
        #expect(roundTripped.ttl == original.ttl)
        #expect(roundTripped.metadata == original.metadata)
    }

    @Test("Metadata encode/decode: empty dict becomes empty JSON object")
    func metadataEmptyDict() {
        let result = CachedAPIResult(
            artist: "A",
            album: "B",
            year: nil,
            source: "test",
            timestamp: .now,
            ttl: nil,
            metadata: [:]
        )

        let row = CachedAPIRow(from: result)

        #expect(row.metadata == "{}")

        let decoded = row.toCachedAPIResult()
        #expect(decoded.metadata.isEmpty)
    }

    @Test("Metadata encode/decode: populated dict round-trips")
    func metadataPopulatedDict() {
        let metadata = ["foo": "bar", "baz": "qux"]
        let result = CachedAPIResult(
            artist: "A",
            album: "B",
            year: nil,
            source: "test",
            timestamp: .now,
            ttl: nil,
            metadata: metadata
        )

        let row = CachedAPIRow(from: result)
        let decoded = row.toCachedAPIResult()

        #expect(decoded.metadata == metadata)
    }

    @Test("Metadata decode: invalid JSON falls back to empty dict")
    func metadataInvalidJSONFallback() {
        let timestamp = Date.now
        let result = CachedAPIResult(
            artist: "A",
            album: "B",
            year: nil,
            source: "test",
            timestamp: timestamp,
            ttl: nil
        )

        var row = CachedAPIRow(from: result)
        row.metadata = "not valid json"

        let decoded = row.toCachedAPIResult()
        #expect(decoded.metadata.isEmpty)
    }

    // MARK: - AlbumYearRow

    @Test("init(from:) maps all fields from AlbumCacheEntry")
    func albumYearRowInitMapsAllFields() {
        let timestamp = Date.now
        let entry = AlbumCacheEntry(
            artist: "Beatles",
            album: "Abbey Road",
            year: 1969,
            confidence: 85,
            timestamp: timestamp
        )

        let row = AlbumYearRow(from: entry)

        #expect(row.artist == "Beatles")
        #expect(row.album == "Abbey Road")
        #expect(row.year == 1969)
        #expect(row.confidence == 85)
        #expect(row.timestamp == timestamp)
    }

    @Test("toAlbumCacheEntry() round-trips all fields")
    func albumYearRowRoundTrip() {
        let timestamp = Date.now
        let original = AlbumCacheEntry(
            artist: "Beatles",
            album: "Abbey Road",
            year: 1969,
            confidence: 85,
            timestamp: timestamp
        )

        let roundTripped = AlbumYearRow(from: original).toAlbumCacheEntry()

        #expect(roundTripped == original)
    }

    // MARK: - GenericCacheRow

    @Test("isExpired with nil TTL returns false (never expires)")
    func genericCacheRowNilTTLNeverExpires() {
        let row = GenericCacheRow(
            key: "test",
            value: Data(),
            ttl: nil,
            timestamp: Date.distantPast
        )

        #expect(row.isExpired == false)
    }

    @Test("isExpired with recent timestamp and TTL returns false")
    func genericCacheRowRecentNotExpired() {
        let row = GenericCacheRow(
            key: "test",
            value: Data(),
            ttl: 3600,
            timestamp: .now
        )

        #expect(row.isExpired == false)
    }

    @Test("isExpired with old timestamp and TTL returns true")
    func genericCacheRowOldTimestampExpired() {
        let row = GenericCacheRow(
            key: "test",
            value: Data(),
            ttl: 60,
            timestamp: Date.now.addingTimeInterval(-120)
        )

        #expect(row.isExpired == true)
    }
}
