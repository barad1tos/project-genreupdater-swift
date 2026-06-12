import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — negative API cache")
struct APIOrchestratorNegativeCacheTests {
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
        let orchestrator = APIOrchestrator(
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
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult()),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true),
            cache: cache,
            negativeResultTTL: 123
        )

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
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(shouldThrow: true),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true),
            cache: cache,
            negativeResultTTL: 123
        )

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
}
