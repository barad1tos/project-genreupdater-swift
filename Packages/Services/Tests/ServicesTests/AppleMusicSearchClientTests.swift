// AppleMusicSearchClientTests.swift — Unit tests for Apple Music catalog client
// Phase 4: API + Cache
//
// MusicKit requires an entitlement and running app context for catalog searches.
// Unit tests here verify only non-MusicKit logic. Catalog search coverage lives
// in the app-hosted IntegrationTests target.

import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - AppleMusicSearchClientTests

@Suite("AppleMusicSearchClient — Apple Music catalog search via MusicKit")
struct AppleMusicSearchClientTests {
    @Test("Client conforms to ExternalAPIService")
    func conformsToProtocol() {
        requireExternalAPIService(AppleMusicSearchClient())
    }

    @Test("getArtistActivityPeriod returns nil pair — MusicKit does not expose this")
    func artistActivityPeriodReturnsNil() async throws {
        let client = AppleMusicSearchClient()
        let (start, end) = try await client.getArtistActivityPeriod(
            normalizedArtist: "Test Artist"
        )
        #expect(start == nil)
        #expect(end == nil)
    }

    @Test("getArtistStartYear returns earliest matching iTunes album release year")
    func artistStartYearUsesEarliestMatchingITunesAlbum() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleMusicSearchMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            AppleMusicSearchMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        AppleMusicSearchMockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.host == "itunes.apple.com")
            #expect(components.path == "/search")

            let queryItems = try #require(components.queryItems)
            #expect(queryItems.first { $0.name == "term" }?.value == "Test Artist")
            #expect(queryItems.first { $0.name == "country" }?.value == "US")
            #expect(queryItems.first { $0.name == "entity" }?.value == "album")
            #expect(queryItems.first { $0.name == "limit" }?.value == "200")

            let json = """
            {
                "resultCount": 3,
                "results": [
                    {
                        "artistName": "Test Artist",
                        "collectionName": "Later Album",
                        "releaseDate": "2001-05-01T07:00:00Z"
                    },
                    {
                        "artistName": "Test Artist",
                        "collectionName": "Debut Album",
                        "releaseDate": "1998-01-01T08:00:00Z"
                    },
                    {
                        "artistName": "Other Artist",
                        "collectionName": "Older Album",
                        "releaseDate": "1980-01-01T08:00:00Z"
                    }
                ]
            }
            """

            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }

        let client = AppleMusicSearchClient(session: session, countryCode: "US")
        let year = try await client.getArtistStartYear(normalizedArtist: "Test Artist")
        #expect(year == 1998)
    }

    private func requireExternalAPIService(_ service: any ExternalAPIService) {
        _ = service
    }
}

private final class AppleMusicSearchMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "itunes.apple.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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

    override func stopLoading() {}
}
