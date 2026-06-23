import Foundation
import Testing
@testable import Core
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

        let baseURL = try makeDiscogsSandboxBaseURL()
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
        #expect(requests.map { $0.url?.host } == [discogsSandboxHost, discogsSandboxHost])
        #expect(requests.map { $0.url?.path } == [discogsSearchPath, discogsCanonicalPath])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Discogs token=test-token-123"
        })
    }

    @Test("getAlbumYear falls back when canonical year is invalid")
    func getAlbumYearFallsBackFromInvalidCanonicalYear() async throws {
        let session = makeDiscogsMockSession { request in
            try makeDiscogsResponse(
                for: request,
                searchJSON: discogsSearchWithInvalidFirstYearResponseJSON,
                canonicalJSON: discogsInvalidReleaseResponseJSON
            )
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try makeDiscogsSandboxBaseURL()
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

    @Test("getAlbumYear falls back when canonical detail returns HTTP error")
    func getAlbumYearFallsBackFromCanonicalDetailHTTPError() async throws {
        try await assertGetAlbumYearFallsBackFromCanonicalDetailFailure { url in
            try makeDiscogsJSONResponse(url: url, json: "{}", statusCode: 500)
        }
    }

    @Test("getAlbumYear falls back when canonical detail transport fails")
    func getAlbumYearFallsBackFromCanonicalDetailTransportFailure() async throws {
        try await assertGetAlbumYearFallsBackFromCanonicalDetailFailure { _ in
            throw URLError(.timedOut)
        }
    }

    private func assertGetAlbumYearFallsBackFromCanonicalDetailFailure(
        canonicalResponse: @escaping (URL) throws -> (HTTPURLResponse, Data)
    ) async throws {
        let session = makeDiscogsMockSession { request in
            let url = try #require(request.url)
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsSearchResponseJSON)
            case discogsCanonicalPath:
                return try canonicalResponse(url)
            default:
                throw URLError(.badURL)
            }
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try makeDiscogsSandboxBaseURL()
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
        #expect(result.yearScores[1984] == 60)
    }

    @Test("getAlbumYear ignores invalid canonical and search years")
    func getAlbumYearIgnoresInvalidCanonicalAndSearchYears() async throws {
        let session = makeDiscogsMockSession { request in
            try makeDiscogsResponse(
                for: request,
                searchJSON: discogsInvalidSearchResponseJSON,
                canonicalJSON: discogsInvalidReleaseResponseJSON
            )
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try makeDiscogsSandboxBaseURL()
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

    @Test("getAlbumYear recovers missing search year from release detail year")
    func getAlbumYearRecoversMissingSearchYearFromReleaseDetailYear() async throws {
        let lookup = try await getAlbumYear { url in
            try makeAlbumYearReleaseFallbackResponse(url: url)
        }

        #expect(lookup.result.year == 1984)
        #expect(lookup.result.yearScores[1984] == 60)
        #expect(lookup.requests.map { $0.url?.path } == [
            discogsSearchPath,
            discogsSearchPath,
            discogsReleaseDetailPath,
        ])
        #expect(lookup.requests.compactMap { request in
            request.url.flatMap { queryValue("type", in: $0) }
        } == ["master", "release"])
    }

    @Test("getAlbumYear recovers missing search year from release detail released date")
    func getAlbumYearRecoversMissingSearchYearFromReleaseDetailReleasedDate() async throws {
        let lookup = try await getAlbumYear { url in
            try makeAlbumYearReleaseFallbackResponse(
                url: url,
                releaseDetailJSON: discogsReleaseDetailReleasedDateResponseJSON
            )
        }

        #expect(lookup.result.year == 1984)
        #expect(lookup.result.yearScores[1984] == 60)
        #expect(lookup.requests.map { $0.url?.path } == [
            discogsSearchPath,
            discogsSearchPath,
            discogsReleaseDetailPath,
        ])
    }

    @Test("getAlbumYear does not fetch release detail for valid search year")
    func getAlbumYearDoesNotFetchReleaseDetailForValidSearchYear() async throws {
        let lookup = try await getAlbumYear { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsValidReleaseSearchResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }

        #expect(lookup.result.year == 1984)
        #expect(lookup.requests.map { $0.url?.path } == [discogsSearchPath])
    }

    @Test("getAlbumYear tolerates release detail failure when another search year is usable")
    func getAlbumYearToleratesReleaseDetailFailureWhenAnotherSearchYearIsUsable() async throws {
        let lookup = try await getAlbumYear { url in
            try makeAlbumYearReleaseFallbackResponse(
                url: url,
                releaseSearchJSON: discogsInvalidThenValidSearchResponseJSON,
                releaseDetailJSON: "{}",
                releaseDetailStatusCode: 500
            )
        }

        #expect(lookup.result.year == 1984)
        #expect(lookup.result.yearScores[1984] == 60)
        #expect(lookup.requests.map { $0.url?.path } == [
            discogsSearchPath,
            discogsSearchPath,
            discogsReleaseDetailPath,
        ])
    }

    @Test("getAlbumYear does not fetch release detail for invalid non-release search result")
    func getAlbumYearDoesNotFetchReleaseDetailForInvalidNonReleaseSearchResult() async throws {
        let lookup = try await getAlbumYear { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsInvalidSearchResponseJSON)
            case discogsCanonicalPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsInvalidReleaseResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }

        #expect(lookup.result.year == nil)
        #expect(lookup.requests.map { $0.url?.path } == [
            discogsSearchPath,
            discogsCanonicalPath,
            discogsSearchPath,
        ])
        #expect(lookup.requests.map { $0.url?.path }.contains(discogsReleaseDetailPath) == false)
        #expect(lookup.requests.compactMap { request in
            request.url.flatMap { queryValue("type", in: $0) }
        } == ["master", "release"])
    }

    @Test("getAlbumYear propagates unauthorized release detail errors")
    func getAlbumYearPropagatesUnauthorizedReleaseDetailErrors() async throws {
        try await expectDiscogsError(.unauthorized) {
            try await getAlbumYearWithReleaseDetailStatus(401)
        }
    }

    @Test("getAlbumYear propagates rate-limited release detail errors")
    func getAlbumYearPropagatesRateLimitedReleaseDetailErrors() async throws {
        try await expectDiscogsError(.rateLimited) {
            try await getAlbumYearWithReleaseDetailStatus(429)
        }
    }

    @Test("getAlbumYear propagates invalid release detail responses")
    func getAlbumYearPropagatesInvalidReleaseDetailResponses() async throws {
        let session = makeDiscogsMockSessionWithRawResponse { request in
            let url = try #require(request.url)
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsMissingSearchYearResponseJSON)
            case discogsReleaseDetailPath:
                return (URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
            default:
                throw URLError(.badURL)
            }
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try makeDiscogsSandboxBaseURL()
        let client = DiscogsClient(
            token: "test-token-123",
            session: session,
            baseURL: baseURL
        )

        try await expectDiscogsError(.invalidResponse) {
            _ = try await client.getAlbumYear(
                artist: "Iron Maiden",
                album: "Powerslave",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
    }

    @Test("getReleaseCandidates recovers missing search year from release detail")
    func getReleaseCandidatesRecoversMissingSearchYearFromReleaseDetail() async throws {
        let lookup = try await getReleaseCandidates { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsMissingSearchYearResponseJSON)
            case discogsReleaseDetailPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsReleaseDetailYearResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(lookup.requests.map { $0.url?.path } == [discogsSearchPath, discogsReleaseDetailPath])
    }

    func getAlbumYear(
        response: @escaping (URL) throws -> (HTTPURLResponse, Data)
    ) async throws -> (result: YearResult, requests: [URLRequest]) {
        let recorder = DiscogsRequestRecorder()
        let session = makeDiscogsMockSession { request in
            recorder.append(request)
            let url = try #require(request.url)
            return try response(url)
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try makeDiscogsSandboxBaseURL()
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

        return (result, recorder.snapshot)
    }

    private func getAlbumYearWithReleaseDetailStatus(_ statusCode: Int) async throws {
        _ = try await getAlbumYear { url in
            try makeAlbumYearReleaseFallbackResponse(
                url: url,
                releaseDetailJSON: "{}",
                releaseDetailStatusCode: statusCode
            )
        }
    }

    func getReleaseCandidates(
        response: @escaping (URL) throws -> (HTTPURLResponse, Data)
    ) async throws -> (candidates: [ReleaseCandidate], requests: [URLRequest]) {
        let recorder = DiscogsRequestRecorder()
        let session = makeDiscogsMockSession { request in
            recorder.append(request)
            let url = try #require(request.url)
            return try response(url)
        }
        defer {
            DiscogsRequestMockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let baseURL = try makeDiscogsSandboxBaseURL()
        let client = DiscogsClient(
            token: "test-token-123",
            session: session,
            baseURL: baseURL
        )
        let candidates = try await client.getReleaseCandidates(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        return (candidates, recorder.snapshot)
    }
}

private func expectDiscogsError(
    _ expected: DiscogsError,
    performing operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        Issue.record("Expected DiscogsError.\(expected)")
    } catch let error as DiscogsError {
        #expect(error.matches(expected))
    }
}

final class DiscogsRequestRecorder: @unchecked Sendable {
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

func makeDiscogsMockSession(
    requestHandler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    makeDiscogsMockSessionWithRawResponse(requestHandler: requestHandler)
}

private func makeDiscogsMockSessionWithRawResponse(
    requestHandler: @escaping (URLRequest) throws -> (URLResponse, Data)
) -> URLSession {
    DiscogsRequestMockURLProtocol.requestHandler = requestHandler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiscogsRequestMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

func makeDiscogsSandboxBaseURL() throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = discogsSandboxHost
    return try #require(components.url)
}

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func makeDiscogsResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
    try makeDiscogsResponse(
        for: request,
        searchJSON: discogsSearchResponseJSON,
        canonicalJSON: discogsReleaseResponseJSON
    )
}

private func makeDiscogsResponse(
    for request: URLRequest,
    searchJSON: String,
    canonicalJSON: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let json = switch url.path {
    case discogsSearchPath:
        searchJSON
    case discogsCanonicalPath:
        canonicalJSON
    default:
        throw URLError(.badURL)
    }
    return try makeDiscogsJSONResponse(url: url, json: json)
}

func makeDiscogsJSONResponse(
    url: URL,
    json: String,
    statusCode: Int = 200
) throws -> (HTTPURLResponse, Data) {
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    return (response, Data(json.utf8))
}

func makeDiscogsTestPath(_ components: String...) -> String {
    let pathSeparator = String(Unicode.Scalar(UInt8(47)))
    return pathSeparator + components.joined(separator: pathSeparator)
}

private func makeAlbumYearReleaseFallbackResponse(
    url: URL,
    releaseSearchJSON: String = discogsMissingSearchYearResponseJSON,
    releaseDetailJSON: String = discogsReleaseDetailYearResponseJSON,
    releaseDetailStatusCode: Int = 200
) throws -> (HTTPURLResponse, Data) {
    switch url.path {
    case discogsSearchPath where queryValue("type", in: url) == "master":
        return try makeDiscogsJSONResponse(url: url, json: discogsMissingCanonicalSearchYearJSON)
    case discogsSearchPath where queryValue("type", in: url) == "release":
        return try makeDiscogsJSONResponse(url: url, json: releaseSearchJSON)
    case discogsReleaseDetailPath:
        return try makeDiscogsJSONResponse(
            url: url,
            json: releaseDetailJSON,
            statusCode: releaseDetailStatusCode
        )
    default:
        throw URLError(.badURL)
    }
}

private let discogsSandboxHost = "sandbox.discogs.com"
private let discogsSearchPath = makeDiscogsTestPath("database", "search")
private let discogsCanonicalPath = makeDiscogsTestPath("masters", "12345")
private let discogsReleaseDetailPath = makeDiscogsTestPath("releases", "42")

final class DiscogsRequestMockURLProtocol: URLProtocol {
    // Safety: each test installs this handler before constructing its isolated URLSession.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (URLResponse, Data))?

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

extension DiscogsError {
    func matches(_ other: DiscogsError) -> Bool {
        switch (self, other) {
        case (.noToken, .noToken),
             (.invalidResponse, .invalidResponse),
             (.unauthorized, .unauthorized),
             (.rateLimited, .rateLimited):
            true
        case let (.httpError(code), .httpError(otherCode)):
            code == otherCode
        default:
            false
        }
    }
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

private let discogsMissingCanonicalSearchYearJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 1 },
  "results": [
    {
      "id": 41,
      "type": "master",
      "title": "Iron Maiden - Powerslave",
      "year": null
    }
  ]
}
"""

private let discogsMissingSearchYearResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 1 },
  "results": [
    {
      "id": 42,
      "type": "release",
      "title": "Iron Maiden - Powerslave",
      "year": null
    }
  ]
}
"""

private let discogsValidReleaseSearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 1 },
  "results": [
    {
      "id": 42,
      "type": "release",
      "title": "Iron Maiden - Powerslave",
      "year": "1984"
    }
  ]
}
"""

private let discogsInvalidThenValidSearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 2 },
  "results": [
    {
      "id": 42,
      "type": "release",
      "title": "Iron Maiden - Powerslave",
      "year": null
    },
    {
      "id": 43,
      "type": "release",
      "title": "Iron Maiden - Powerslave",
      "year": "1984"
    }
  ]
}
"""

private let discogsSearchWithInvalidFirstYearResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 2 },
  "results": [
    {
      "id": 42,
      "type": "master",
      "master_id": 12345,
      "title": "Iron Maiden - Powerslave",
      "year": "0"
    },
    {
      "id": 43,
      "type": "release",
      "title": "Iron Maiden - Powerslave",
      "year": "1984"
    }
  ]
}
"""

private let discogsReleaseDetailYearResponseJSON = """
{
  "id": 42,
  "title": "Powerslave",
  "year": 1984,
  "released": null
}
"""

private let discogsReleaseDetailReleasedDateResponseJSON = """
{
  "id": 42,
  "title": "Powerslave",
  "year": 0,
  "released": "1984-09-03"
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
