import Foundation
import Testing
@testable import Core
@testable import Services

/// Python request_executor parity: the shared response cache answers
/// before the limiter, both polarities cached under one TTL.
@Suite("Raw API request cache")
struct RawAPIRequestCacheTests {
    private let url = URL(string: "https://api.example.com/search?artist=daft&album=ram")

    @Test("A hit returns cached bytes without fetching")
    func hitSkipsFetch() async throws {
        let cache = MockCacheService()
        let raw = RawAPIRequestCache(cache: cache, ttl: 3600)
        let counter = FetchCounter()
        let target = try #require(url)

        let first = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("payload".utf8)
        }
        let second = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("DIFFERENT".utf8)
        }

        #expect(first == Data("payload".utf8))
        #expect(second == Data("payload".utf8))
        #expect(await counter.count == 1)
    }

    @Test("A failed fetch caches the miss and a cached miss fails fast")
    func failureCachesMiss() async throws {
        let cache = MockCacheService()
        let raw = RawAPIRequestCache(cache: cache, ttl: 3600)
        let counter = FetchCounter()
        let target = try #require(url)

        await #expect(throws: FetchFailure.self) {
            try await raw.data(api: "mb", url: target) {
                await counter.increment()
                throw FetchFailure.boom
            }
        }
        await #expect(throws: RawAPIRequestCacheError.self) {
            try await raw.data(api: "mb", url: target) {
                await counter.increment()
                return Data()
            }
        }

        #expect(await counter.count == 1)
    }

    @Test("Cancellation caches nothing")
    func cancellationCachesNothing() async throws {
        let cache = MockCacheService()
        let raw = RawAPIRequestCache(cache: cache, ttl: 3600)
        let counter = FetchCounter()
        let target = try #require(url)

        await #expect(throws: CancellationError.self) {
            try await raw.data(api: "mb", url: target) {
                await counter.increment()
                throw CancellationError()
            }
        }
        let recovered = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("late".utf8)
        }

        #expect(recovered == Data("late".utf8))
        #expect(await counter.count == 2)
    }

    @Test("Reordered query items share one cache entry")
    func reorderedQuerySharesEntry() throws {
        let ordered = try #require(URL(string: "https://api.example.com/search?a=1&b=2"))
        let reordered = try #require(URL(string: "https://api.example.com/search?b=2&a=1"))
        let different = try #require(URL(string: "https://api.example.com/search?a=1&b=3"))

        #expect(
            RawAPIRequestCache.cacheKey(api: "mb", url: ordered)
                == RawAPIRequestCache.cacheKey(api: "mb", url: reordered)
        )
        #expect(
            RawAPIRequestCache.cacheKey(api: "mb", url: ordered)
                != RawAPIRequestCache.cacheKey(api: "mb", url: different)
        )
        #expect(
            RawAPIRequestCache.cacheKey(api: "mb", url: ordered)
                != RawAPIRequestCache.cacheKey(api: "discogs", url: ordered)
        )
    }
}

private actor FetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private enum FetchFailure: Error {
    case boom
}
