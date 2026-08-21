import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Provider default pacing", .serialized)
struct ProviderPacingTests {
    @Test("Discogs direct clients do not retain the former initial burst")
    func discogsDefault() async throws {
        let timeline = RequestTimeline()
        let session = makePacingSession(timeline: timeline)
        defer { session.invalidateAndCancel() }
        let client = DiscogsClient(
            token: "test-token",
            session: session,
            baseURL: DiscogsClient.defaultBaseURL
        )
        #expect(DiscogsClient.defaultPolicy == .init(maxTokens: 1, refillInterval: .milliseconds(1091)))

        _ = try await client.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        _ = try await client.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let delay = try timeline.firstRequestDelay()
        #expect(delay >= .milliseconds(500))
        #expect(delay < .seconds(2))
    }

    @Test("MusicBrainz direct clients use the centralized one-second default")
    func musicBrainzDefault() async throws {
        let timeline = RequestTimeline()
        let session = makePacingSession(timeline: timeline)
        defer { session.invalidateAndCancel() }
        let client = MusicBrainzClient(session: session)
        #expect(MusicBrainzClient.defaultPolicy == .init(maxTokens: 1, refillInterval: .seconds(1)))

        _ = try await client.getArtistRegion(artist: "Test Artist")
        _ = try await client.getArtistRegion(artist: "Test Artist")

        let delay = try timeline.firstRequestDelay()
        #expect(delay >= .milliseconds(400))
        #expect(delay < .seconds(2))
    }

    @Test("iTunes direct clients use the centralized ten-per-second default")
    func itunesDefault() async throws {
        let timeline = RequestTimeline()
        let session = makePacingSession(timeline: timeline)
        defer { session.invalidateAndCancel() }
        let client = CatalogSearchClient(session: session, lookupFallbackEnabled: false)
        #expect(CatalogSearchClient.defaultPolicy == .init(maxTokens: 1, refillInterval: .milliseconds(100)))

        _ = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        _ = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let delay = try timeline.firstRequestDelay()
        #expect(delay >= .milliseconds(20))
        #expect(delay < .milliseconds(500))
    }
}

private final class RequestTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [ContinuousClock.Instant] = []

    func record() {
        lock.withLock {
            starts.append(ContinuousClock().now)
        }
    }

    func firstRequestDelay() throws -> Duration {
        try lock.withLock {
            let first = try #require(starts.first)
            let second = try #require(starts.dropFirst().first)
            return first.duration(to: second)
        }
    }
}

private func makePacingSession(timeline: RequestTimeline) -> URLSession {
    PacingURLProtocol.timeline = timeline
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PacingURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class PacingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var timeline: RequestTimeline?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let timeline = Self.timeline else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        timeline.record()
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data = Data(responseJSON(for: url).utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Responses are delivered synchronously, so there is no pending load to cancel.
    }

    private func responseJSON(for url: URL) -> String {
        switch url.host {
        case "itunes.apple.com":
            """
            {
              "resultCount": 1,
              "results": [{
                "artistName": "Test Artist",
                "collectionName": "Test Album",
                "releaseDate": "1998-01-01T00:00:00Z",
                "country": "US"
              }]
            }
            """
        case "musicbrainz.org":
            """
            {"artists":[{"id":"artist-1","name":"Test Artist","area":{"name":"United States"}}]}
            """
        default:
            """
            {
              "pagination": {"page": 1, "pages": 1, "per_page": 1, "items": 1},
              "results": [{
                "id": 42,
                "type": "master",
                "master_id": 12345,
                "title": "Iron Maiden - Powerslave",
                "year": "1984"
              }]
            }
            """
        }
    }
}
