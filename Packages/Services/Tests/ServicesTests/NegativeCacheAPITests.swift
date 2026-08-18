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

    @Test("Discogs direct-year cache follows result-limit changes")
    func discogsResultLimitTransition() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let initialConfiguration = discogsSearch(resultLimit: 1, detailLookupLimit: 0)

        let initialResult = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: initialConfiguration,
            serviceYear: 1984
        )
        let matchingResult = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: initialConfiguration,
            serviceYear: 1990
        )
        let updatedResult = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: discogsSearch(resultLimit: 2, detailLookupLimit: 0),
            serviceYear: 1999
        )

        #expect(initialResult.year == 1984)
        #expect(matchingResult.year == 1984)
        #expect(updatedResult.year == 1999)
        #expect(await callCounter.count() == 2)
    }

    @Test("Discogs direct-year misses follow detail-limit changes")
    func discogsDetailLimitTransition() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let initialConfiguration = discogsSearch(resultLimit: 1, detailLookupLimit: 0)

        let initialResult = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: initialConfiguration,
            serviceYear: nil
        )
        let matchingResult = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: initialConfiguration,
            serviceYear: 1990
        )
        let updatedResult = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: discogsSearch(resultLimit: 1, detailLookupLimit: 1),
            serviceYear: 1999
        )

        #expect(initialResult.year == nil)
        #expect(matchingResult.year == nil)
        #expect(updatedResult.year == 1999)
        #expect(await callCounter.count() == 2)
    }

    @Test("Discogs direct-year cache bypasses legacy acquisition entries")
    func discogsLegacyAcquisition() async {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: 1984,
            source: "discogs",
            timestamp: .now,
            ttl: 3600,
            metadata: ["confidence": "60"]
        ))
        let callCounter = APICallCounter()

        let result = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: discogsSearch(resultLimit: 25, detailLookupLimit: 10),
            serviceYear: 1999
        )

        #expect(result.year == 1999)
        #expect(await callCounter.count() == 1)
    }

    @Test("Discogs direct-year cache bypasses legacy acquisition misses")
    func discogsLegacyAcquisitionMiss() async {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: nil,
            source: "discogs",
            timestamp: .now,
            ttl: 3600,
            metadata: ["cacheKind": "negative"]
        ))
        let callCounter = APICallCounter()

        let result = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: discogsSearch(resultLimit: 25, detailLookupLimit: 10),
            serviceYear: 1999
        )

        #expect(result.year == 1999)
        #expect(await callCounter.count() == 1)
    }

    @Test("Discogs direct-year cache bypasses revision 2 misses")
    func discogsRevision2Miss() async {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: nil,
            source: "discogs",
            timestamp: .now,
            ttl: 3600,
            metadata: [
                "cacheKind": "negative",
                "discogsAcquisition": "revision=2,result_limit=25,detail_limit=10",
            ]
        ))
        let callCounter = APICallCounter()

        let result = await discogsYear(
            cache: cache,
            callCounter: callCounter,
            searchConfiguration: discogsSearch(resultLimit: 25, detailLookupLimit: 10),
            serviceYear: 1999
        )

        #expect(result.year == 1999)
        #expect(await callCounter.count() == 1)
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

    private func discogsYear(
        cache: any CacheService,
        callCounter: APICallCounter,
        searchConfiguration: DiscogsSearchConfig,
        serviceYear: Int?
    ) async -> YearResult {
        let yearResult = serviceYear.map {
            YearResult(year: $0, confidence: 60, yearScores: [$0: 60])
        } ?? YearResult()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(shouldThrow: true),
            discogs: CountingAPIService(callCounter: callCounter, yearResult: yearResult),
            appleMusic: MockAPIService(shouldThrow: true),
            cache: cache,
            disabledSources: [.musicBrainz, .itunes]
        ) {
            $0.negativeResultTTL = 3600
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(preferredAPI: .discogs)
            $0.discogsSearchConfiguration = searchConfiguration
        }

        return await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
    }

    private func discogsSearch(
        resultLimit: Int,
        detailLookupLimit: Int
    ) -> DiscogsSearchConfig {
        var configuration = DiscogsSearchConfig()
        configuration.resultLimit = resultLimit
        configuration.detailLookupLimit = detailLookupLimit
        return configuration
    }
}
