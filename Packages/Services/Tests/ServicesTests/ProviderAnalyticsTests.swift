import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Provider analytics", .serialized)
struct ProviderAnalyticsTests {
    @Test("MusicBrainz records one release request without changing the result")
    func musicBrainzReleaseSearch() async throws {
        let responseJSON =
            #"{"release-groups":[{"id":"rg-1","title":"Album","primary-type":"Album","first-release-date":"1998"}]}"#
        let analytics = ProviderAnalyticsProbe()
        let session = makeProviderSession { request in
            try providerResponse(for: request, json: responseJSON)
        }
        defer { session.invalidateAndCancel() }
        let client = MusicBrainzClient(
            session: session,
            rateLimiter: fastProviderLimiter(),
            analytics: analytics
        )

        let result = try await client.getAlbumYear(
            artist: "Artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let baselineSession = makeProviderSession { request in
            try providerResponse(for: request, json: responseJSON)
        }
        defer { baselineSession.invalidateAndCancel() }
        let baseline = try await MusicBrainzClient(
            session: baselineSession,
            rateLimiter: fastProviderLimiter()
        ).getAlbumYear(
            artist: "Artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result == baseline)
        let records = await analytics.records
        #expect(records.map(\.operation) == [.musicBrainzReleaseSearch])
        #expect(records.map(\.outcome) == [.succeeded])
    }

    @Test("Discogs fallbacks record only the requests that reached transport")
    func discogsFallback() async throws {
        let analytics = ProviderAnalyticsProbe()
        let session = makeProviderSession { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "artist" }) {
                throw URLError(.timedOut)
            }
            return try providerResponse(
                for: request,
                json: #"{"results":[{"id":1,"type":"release","title":"Iron Maiden - Powerslave","year":1984}]}"#
            )
        }
        defer { session.invalidateAndCancel() }
        let client = DiscogsClient(
            token: "token",
            session: session,
            rateLimiter: fastProviderLimiter()
        ).withAnalytics(analytics)

        let candidates = try await client.getReleaseCandidates(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.year) == [1984])
        let records = await analytics.records
        #expect(records.map(\.operation) == [.discogsReleaseSearch, .discogsReleaseSearch])
        #expect(records.map(\.outcome) == [.failed, .succeeded])
    }

    @Test("A cached iTunes response bypasses transport analytics")
    func iTunesCacheHit() async throws {
        AnalyticsURLProtocol.reset()
        let analytics = ProviderAnalyticsProbe()
        let cache = MockCacheService()
        let session = makeProviderSession { request in
            try providerResponse(
                for: request,
                json: """
                {"resultCount":1,"results":[{"artistName":"Artist","collectionName":"Album",\
                "releaseDate":"2001-01-01T00:00:00Z","country":"US"}]}
                """
            )
        }
        defer { session.invalidateAndCancel() }
        let client = CatalogSearchClient.paced(
            settings: ITunesSearchConfig(),
            rateLimiter: fastProviderLimiter(),
            session: session,
            rawRequestCache: RawAPIRequestCache(cache: cache, ttl: 3600),
            analytics: analytics
        )

        let first = try await client.getReleaseCandidates(
            artist: "Artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let second = try await client.getReleaseCandidates(
            artist: "Artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(first == second)
        #expect(AnalyticsURLProtocol.requestCount == 1)
        let records = await analytics.records
        #expect(records.map(\.operation) == [.iTunesReleaseSearch])
        #expect(records.map(\.outcome) == [.succeeded])
    }

    @Test("Provider cancellation is terminal and records no successor request")
    func cancelledDiscogsRequest() async {
        AnalyticsURLProtocol.reset()
        let analytics = ProviderAnalyticsProbe()
        let session = makeProviderSession { _ in throw URLError(.cancelled) }
        defer { session.invalidateAndCancel() }
        let client = DiscogsClient(
            token: "token",
            session: session,
            rateLimiter: fastProviderLimiter(),
            analytics: analytics
        )

        await #expect(throws: URLError.self) {
            _ = try await client.getReleaseCandidates(
                artist: "Artist",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }

        #expect(AnalyticsURLProtocol.requestCount == 1)
        let records = await analytics.records
        #expect(records.map(\.operation) == [.discogsReleaseSearch])
        #expect(records.map(\.outcome) == [.cancelled])
    }
}

private struct ProviderAnalyticsRecord: Sendable {
    let operation: AnalyticsOperation
    let outcome: AnalyticsOutcome
}

private actor ProviderAnalyticsProbe: AnalyticsService {
    private(set) var records: [ProviderAnalyticsRecord] = []

    func record(_ operation: AnalyticsOperation, duration _: Duration, outcome: AnalyticsOutcome) {
        records.append(ProviderAnalyticsRecord(operation: operation, outcome: outcome))
    }
}

private func fastProviderLimiter() -> TokenBucketRateLimiter {
    TokenBucketRateLimiter(maxTokens: 10, refillInterval: .milliseconds(1))
}

private func makeProviderSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    AnalyticsURLProtocol.reset(handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AnalyticsURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func providerResponse(
    for request: URLRequest,
    json: String,
    statusCode: Int = 200
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    return (response, Data(json.utf8))
}

private final class AnalyticsURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private(set) static var requestCount = 0

    static func reset(handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil) {
        self.handler = handler
        requestCount = 0
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // Responses are delivered synchronously, so there is no pending work to cancel.
    }
}
