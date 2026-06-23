import Foundation
import Testing
@testable import Services

@Suite("DiscogsClient — request execution", .serialized)
struct DiscogsClientRequestTests {
    @Test("getAlbumYear uses configured base URL for search and master requests")
    func getAlbumYearUsesConfiguredBaseURL() async throws {
        let recorder = DiscogsRequestRecorder()
        let session = makeDiscogsMockSession { request in
            recorder.append(request)
            return try makeDiscogsResponse(for: request)
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try #require(URL(string: "https://sandbox.discogs.com"))
        let client = DiscogsClient(
            token: "test-token-123",
            session: session,
            baseURL: baseURL
        )

        let result = try await client.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let requests = recorder.snapshot

        #expect(result.year == 1984)
        #expect(requests.map { $0.url?.host } == ["sandbox.discogs.com", "sandbox.discogs.com"])
        #expect(requests.map { $0.url?.path } == ["/database/search", "/masters/12345"])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Discogs token=test-token-123"
        })
    }

    @Test("getAlbumYear falls back when canonical year is invalid")
    func getAlbumYearFallsBackFromInvalidCanonicalYear() async throws {
        let session = makeDiscogsMockSession { request in
            let url = try #require(request.url)
            let json = switch url.path {
            case "/database/search":
                discogsSearchResponseJSON
            case "/masters/12345":
                discogsInvalidReleaseResponseJSON
            default:
                throw URLError(.badURL)
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try #require(URL(string: "https://sandbox.discogs.com"))
        let client = DiscogsClient(
            token: "test-token-123",
            session: session,
            baseURL: baseURL
        )

        let result = try await client.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1984)
        #expect(result.yearScores[0] == nil)
    }

    @Test("getAlbumYear ignores invalid canonical and search years")
    func getAlbumYearIgnoresInvalidCanonicalAndSearchYears() async throws {
        let session = makeDiscogsMockSession { request in
            let url = try #require(request.url)
            let json = switch url.path {
            case "/database/search":
                discogsInvalidSearchResponseJSON
            case "/masters/12345":
                discogsInvalidReleaseResponseJSON
            default:
                throw URLError(.badURL)
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(json.utf8))
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try #require(URL(string: "https://sandbox.discogs.com"))
        let client = DiscogsClient(
            token: "test-token-123",
            session: session,
            baseURL: baseURL
        )

        let result = try await client.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(result.yearScores[0] == nil)
    }
}

private final class DiscogsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var snapshot: [URLRequest] {
        lock.withLock { requests }
    }

    func append(_ request: URLRequest) {
        lock.withLock {
            requests.append(request)
        }
    }
}

private func makeDiscogsMockSession(
    requestHandler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    DiscogsRequestMockURLProtocol.requestHandler = requestHandler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiscogsRequestMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeDiscogsResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let json = switch url.path {
    case "/database/search":
        discogsSearchResponseJSON
    case "/masters/12345":
        discogsReleaseResponseJSON
    default:
        throw URLError(.badURL)
    }
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    return (response, Data(json.utf8))
}

private final class DiscogsRequestMockURLProtocol: URLProtocol {
    // Safety: each test installs this handler before constructing its isolated URLSession.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".discogs.com") == true
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

private let discogsSearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 1 },
  "results": [
    {
      "id": 42,
      "type": "master",
      "master_id": 12345,
      "title": "Iron Maiden - Powerslave",
      "year": "1984"
    }
  ]
}
"""

private let discogsInvalidSearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 1 },
  "results": [
    {
      "id": 42,
      "type": "master",
      "master_id": 12345,
      "title": "Iron Maiden - Powerslave",
      "year": "0"
    }
  ]
}
"""

private let discogsReleaseResponseJSON = """
{
  "id": 12345,
  "title": "Powerslave",
  "year": 1984,
  "genres": ["Rock"],
  "styles": ["Heavy Metal"]
}
"""

private let discogsInvalidReleaseResponseJSON = """
{
  "id": 12345,
  "title": "Powerslave",
  "year": 0,
  "genres": ["Rock"],
  "styles": ["Heavy Metal"]
}
"""
