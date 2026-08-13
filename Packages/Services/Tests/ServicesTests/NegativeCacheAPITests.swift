import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — negative API cache")
struct NegativeCacheAPITests {
    @Test("Negative cache hit skips matching source request")
    func negativeCacheHitSkipsMatchingSourceRequest() async {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Unknown Artist",
            album: "Unknown Album",
            year: nil,
            source: "musicbrainz",
            timestamp: .now,
            ttl: 3600,
            metadata: [
                "cacheKind": "negative",
            ]
        ))

        let callCounter = APICallCounter()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: CountingAPIService(
                callCounter: callCounter,
                yearResult: YearResult(year: 1999, confidence: 99, yearScores: [1999: 99])
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(await callCounter.count() == 0)
    }

    @Test("Empty source result is cached with negative TTL")
    func emptySourceResultIsCachedWithNegativeTTL() async {
        let cache = MockCacheService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult()),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true),
            cache: cache
        ) {
            $0.negativeResultTTL = 123
        }

        _ = await orchestrator.getAlbumYear(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let cached = await cache.getCachedAPIResult(
            artist: "Unknown Artist",
            album: "Unknown Album",
            source: "musicbrainz"
        )
        #expect(cached?.year == nil)
        #expect(cached?.ttl == 123)
        #expect(cached?.metadata["cacheKind"] == "negative")
    }

    @Test("Failed source result is not cached as negative")
    func failedSourceResultIsNotCachedAsNegative() async {
        let cache = MockCacheService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(shouldThrow: true),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true),
            cache: cache
        ) {
            $0.negativeResultTTL = 123
        }

        _ = await orchestrator.getAlbumYear(
            artist: "Failed Artist",
            album: "Failed Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let cached = await cache.getCachedAPIResult(
            artist: "Failed Artist",
            album: "Failed Album",
            source: "musicbrainz"
        )
        #expect(cached == nil)
    }

    @Test("Off bypasses a durable album-year miss written under a longer policy")
    func offRetriesYear() async throws {
        try await verifyMissRetry(negativeTTL: 0, missAge: 0)
    }

    @Test("A shorter policy bypasses an older durable album-year miss")
    func shorterYearTTL() async throws {
        try await verifyMissRetry(negativeTTL: 1, missAge: 2)
    }

    private func verifyMissRetry(
        negativeTTL: TimeInterval,
        missAge: TimeInterval
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("api-cache.db")

        do {
            let initialCache = try GRDBCacheService(databasePath: databaseURL.path, apiResultTTL: 31_536_000)
            try await initialCache.initialize()
            await initialCache.setCachedAPIResult(CachedAPIResult(
                artist: "Unknown Artist",
                album: "Unknown Album",
                year: nil,
                source: "musicbrainz",
                timestamp: .now.addingTimeInterval(-missAge),
                ttl: 31_536_000,
                metadata: ["cacheKind": "negative"]
            ))
            try await initialCache.syncToDisk()
        }

        let relaunchedCache = try GRDBCacheService(databasePath: databaseURL.path, apiResultTTL: 31_536_000)
        try await relaunchedCache.initialize()
        let callCounter = APICallCounter()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: CountingAPIService(
                callCounter: callCounter,
                yearResult: YearResult(year: 1999, confidence: 99, yearScores: [1999: 99])
            ),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true),
            cache: relaunchedCache
        ) {
            $0.negativeResultTTL = negativeTTL
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1999)
        #expect(await callCounter.count() == 1)
    }
}
