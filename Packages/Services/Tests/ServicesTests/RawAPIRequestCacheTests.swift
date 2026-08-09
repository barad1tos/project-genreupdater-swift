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
            return Data("{\"payload\":1}".utf8)
        }
        let second = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("{\"other\":2}".utf8)
        }

        #expect(first == Data("{\"payload\":1}".utf8))
        #expect(second == Data("{\"payload\":1}".utf8))
        #expect(await counter.count == 1)
    }

    @Test("A failure caches NOTHING — retries live above this seam")
    func failureCachesNothing() async throws {
        // Codex P1: Python caches a failure because its retry loop runs
        // INSIDE execute_request; Swift's retry layer sits above this
        // seam, so caching here would freeze the FIRST transient 429/503
        // for the whole TTL.
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
        let recovered = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("{\"ok\":true}".utf8)
        }

        #expect(recovered == Data("{\"ok\":true}".utf8))
        #expect(await counter.count == 2)
    }

    @Test("A non-JSON body is returned but never cached")
    func nonJSONBodyIsNotCached() async throws {
        // Python caches the PARSED response, so a proxy error page or a
        // truncated body can never become a cache entry.
        let cache = MockCacheService()
        let raw = RawAPIRequestCache(cache: cache, ttl: 3600)
        let counter = FetchCounter()
        let target = try #require(url)

        let first = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("<html>502</html>".utf8)
        }
        let second = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("{\"ok\":true}".utf8)
        }

        #expect(first == Data("<html>502</html>".utf8))
        #expect(second == Data("{\"ok\":true}".utf8))
        #expect(await counter.count == 2)
    }

    @Test("An oversized body is returned but never cached")
    func oversizedBodyIsNotCached() async throws {
        // Panel M5: raw bodies share the generic table's row budget with
        // the derived caches — a huge iTunes page must not evict them.
        let cache = MockCacheService()
        let raw = RawAPIRequestCache(cache: cache, ttl: 3600)
        let counter = FetchCounter()
        let target = try #require(url)
        let huge = Data(("[" + String(repeating: "1,", count: 200_000) + "1]").utf8)
        #expect(huge.count > RawAPIRequestCache.maximumCachedBodyBytes)

        _ = try await raw.data(api: "itunes", url: target) {
            await counter.increment()
            return huge
        }
        _ = try await raw.data(api: "itunes", url: target) {
            await counter.increment()
            return Data("{\"ok\":true}".utf8)
        }

        #expect(await counter.count == 2)
    }

    @Test("Entries expire with the configured TTL")
    func entriesExpireWithTTL() async throws {
        // The headline claim needs its own guard: a nil TTL would make
        // every pin above pass while entries never expired.
        let cache = MockCacheService()
        let raw = RawAPIRequestCache(cache: cache, ttl: 0.05)
        let counter = FetchCounter()
        let target = try #require(url)

        _ = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("{\"first\":1}".utf8)
        }
        try await Task.sleep(for: .milliseconds(120))
        let refreshed = try await raw.data(api: "mb", url: target) {
            await counter.increment()
            return Data("{\"second\":2}".utf8)
        }

        #expect(refreshed == Data("{\"second\":2}".utf8))
        #expect(await counter.count == 2)
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
            return Data("{\"late\":true}".utf8)
        }

        #expect(recovered == Data("{\"late\":true}".utf8))
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

        // Custom base URLs may differ only by port (Codex P2).
        let plain = try #require(URL(string: "https://host/search?a=1"))
        let ported = try #require(URL(string: "https://host:8443/search?a=1"))
        #expect(
            RawAPIRequestCache.cacheKey(api: "mb", url: plain)
                != RawAPIRequestCache.cacheKey(api: "mb", url: ported)
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
