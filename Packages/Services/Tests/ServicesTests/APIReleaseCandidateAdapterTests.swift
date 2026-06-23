import Foundation
import Testing
@testable import Core
@testable import Services

private let musicBrainzArtistPathComponents = ["ws", "2", "artist"]
private let musicBrainzReleasePathComponents = ["ws", "2", "release"]
private let musicBrainzReleaseGroupPathComponents = ["ws", "2", "release-group"]

@Suite("API release candidate adapters", .serialized)
struct APIReleaseCandidateAdapterTests {
    @Test("MusicBrainz returns release candidates from release groups")
    func musicBrainzReleaseCandidates() async throws {
        let client = makeMockMusicBrainzClient(json: """
            {
              "release-groups": [
                {
                  "id": "rg-1",
                  "title": "Test Album",
                  "first-release-date": "1998-01-01",
                  "primary-type": "Album"
                },
                {
                  "id": "rg-2",
                  "title": "Test Album (Remastered)",
                  "first-release-date": "2020-01-01",
                  "primary-type": "Album"
                }
              ]
            }
            """
        )

        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let firstCandidate = try #require(candidates.first)
        #expect(candidates.map(\.year) == [1998, 2020])
        #expect(candidates.allSatisfy { $0.source == .musicBrainz })
        #expect(firstCandidate.mbReleaseGroupID == "rg-1")
        #expect(firstCandidate.mbReleaseGroupFirstYear == 1998)
    }

    @Test("MusicBrainz release candidates preserve release details")
    func musicBrainzReleaseCandidatesPreserveReleaseDetails() async throws {
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw URLError(.badURL)
            }

            let requestPathComponents = Array(url.pathComponents.dropFirst())
            if requestPathComponents == musicBrainzReleaseGroupPathComponents {
                let json = """
                {
                  "release-groups": [
                    {
                      "id": "rg-1",
                      "title": "Test Album",
                      "first-release-date": "1998-01-01",
                      "primary-type": "Album"
                    }
                  ]
                }
                """
                return try (jsonResponse(url: url), Data(json.utf8))
            }

            let queryItems = components.queryItems ?? []
            if requestPathComponents == musicBrainzReleasePathComponents,
               queryItems.contains(where: { $0.name == "release-group" && $0.value == "rg-1" }) {
                let json = """
                {
                  "releases": [
                    {
                      "id": "rel-1",
                      "title": "Test Album",
                      "date": "1999-05-01",
                      "country": "GB",
                      "status": "Promotion",
                      "media": [{ "format": "CD" }],
                      "artist-credit": [{ "name": "Test Artist" }]
                    }
                  ]
                }
                """
                return try (jsonResponse(url: url), Data(json.utf8))
            }

            throw URLError(.badURL)
        }
        defer { APIReleaseCandidateMockURLProtocol.requestHandler = nil }

        let client = makeMockMusicBrainzClient()
        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let candidate = try #require(candidates.first)
        #expect(candidate.year == 1998)
        #expect(candidate.country == "gb")
        #expect(candidate.status == .promotional)
        #expect(candidate.mbReleaseGroupID == "rg-1")
        #expect(candidate.mbReleaseGroupFirstYear == 1998)
    }

    @Test("MusicBrainz retries non-Latin release group search with canonical artist")
    func musicBrainzCanonicalArtistFallbackForNonLatinArtist() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            let (url, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)

            let json: String
            let requestPathComponents = Array(url.pathComponents.dropFirst())
            let isOriginalReleaseGroupQuery = requestPathComponents == musicBrainzReleaseGroupPathComponents
                && query.contains("artist:\"паліндром\"")
            let isCanonicalArtistQuery = requestPathComponents == musicBrainzArtistPathComponents
                && query.contains("artist:\"паліндром\"")
            let isCanonicalReleaseGroupQuery = requestPathComponents == musicBrainzReleaseGroupPathComponents
                && query.contains("artist:\"palindrom\"")

            if isOriginalReleaseGroupQuery {
                json = #"{"release-groups":[]}"#
            } else if isCanonicalArtistQuery {
                json = #"{"artists":[{"id":"artist-pal","name":"Palindrom","type":"Person"}]}"#
            } else if isCanonicalReleaseGroupQuery {
                json = """
                {
                  "release-groups": [
                    {
                      "id": "rg-pal",
                      "title": "Придумано в черзі",
                      "first-release-date": "2021-01-01",
                      "primary-type": "Album"
                    }
                  ]
                }
                """
            } else {
                throw URLError(.badURL)
            }

            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer {
            APIReleaseCandidateMockURLProtocol.requestHandler = nil
            APIReleaseCandidateMockURLProtocol.requestedQueries = []
        }

        let client = makeMockMusicBrainzClient()

        let candidates = try await client.getReleaseCandidates(
            artist: "паліндром",
            album: "Придумано в черзі",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.year) == [2021])
        let requestedQueries = APIReleaseCandidateMockURLProtocol.requestedQueries
        #expect(requestedQueries.count == 3)
        if requestedQueries.count == 3 {
            #expect(requestedQueries[1].contains("artist:\"паліндром\""))
            #expect(requestedQueries[2].contains("artist:\"palindrom\""))
        }
    }

    @Test("MusicBrainz skips canonical artist lookup for Latin artist aliases")
    func musicBrainzSkipsCanonicalArtistFallbackForLatinArtist() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            let (url, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)

            let requestPathComponents = Array(url.pathComponents.dropFirst())
            guard requestPathComponents == musicBrainzReleaseGroupPathComponents else {
                throw URLError(.badURL)
            }
            return try (jsonResponse(url: url), Data(#"{"release-groups":[]}"#.utf8))
        }
        defer {
            APIReleaseCandidateMockURLProtocol.requestHandler = nil
            APIReleaseCandidateMockURLProtocol.requestedQueries = []
        }

        let client = makeMockMusicBrainzClient()

        let candidates = try await client.getReleaseCandidates(
            artist: "Björk",
            album: "Debut",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.isEmpty)
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries.count == 1)
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries.first?.contains("artist:\"Björk\"") == true)
    }

    @Test("Discogs returns release candidates from search results")
    func discogsReleaseCandidates() async throws {
        let client = DiscogsClient(
            token: "test-token",
            session: makeMockSession(json: """
            {
              "results": [
                {
                  "id": 1,
                  "title": "Test Artist - Test Album",
                  "year": 1998,
                  "type": "master",
                  "country": "US",
                  "format": ["Album"]
                },
                {
                  "id": 2,
                  "title": "Test Artist - Test Album",
                  "year": 2020,
                  "type": "release",
                  "country": "US",
                  "format": ["Album", "Remastered"]
                }
              ]
            }
            """)
        )

        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let secondCandidate = try #require(candidates.dropFirst().first)
        #expect(candidates.map(\.year) == [1998, 2020])
        #expect(candidates.allSatisfy { $0.source == .discogs })
        #expect(secondCandidate.isReissue)
    }

    @Test("Discogs release candidates prefer canonical year details")
    func discogsReleaseCandidatesPreferCanonicalYearDetails() async throws {
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let pathComponents = Array(url.pathComponents.dropFirst())

            if pathComponents == ["database", "search"] {
                let json = """
                {
                  "results": [
                    {
                      "id": 2,
                      "title": "Test Artist - Test Album (Remastered)",
                      "year": 2020,
                      "type": "release",
                      "master_id": 42,
                      "country": "US",
                      "format": ["Album"],
                      "genre": [],
                      "style": ["Alternative Rock"]
                    }
                  ]
                }
                """
                return try (jsonResponse(url: url), Data(json.utf8))
            }

            if pathComponents == ["masters", "42"] {
                let json = """
                {
                  "id": 42,
                  "title": "Test Album",
                  "year": 1998,
                  "genres": ["Rock"],
                  "styles": ["Hard Rock"],
                  "artists": [{ "id": 1, "name": "Test Artist" }]
                }
                """
                return try (jsonResponse(url: url), Data(json.utf8))
            }

            throw URLError(.badURL)
        }
        defer { APIReleaseCandidateMockURLProtocol.requestHandler = nil }

        let client = DiscogsClient(token: "test-token", session: makeMockSession(json: "{}"))
        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let candidate = try #require(candidates.first)
        #expect(candidate.year == 1998)
        #expect(candidate.isReissue)
        #expect(candidate.genre == "Rock")
    }
}

private func makeMockSession(json: String) -> URLSession {
    APIReleaseCandidateMockURLProtocol.responseData = Data(json.utf8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [APIReleaseCandidateMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeMockMusicBrainzClient(json: String = "{}") -> MusicBrainzClient {
    MusicBrainzClient(
        appName: "GenreUpdaterTests",
        contactEmail: "tests@example.invalid",
        session: makeMockSession(json: json)
    )
}

private func musicBrainzQuery(from request: URLRequest) throws -> (url: URL, query: String) {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let query = components.queryItems?.first(where: { $0.name == "query" })?.value
    else {
        throw URLError(.badURL)
    }
    return (url, query)
}

private func jsonResponse(url: URL) throws -> HTTPURLResponse {
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ) else {
        throw URLError(.badServerResponse)
    }
    return response
}

private final class APIReleaseCandidateMockURLProtocol: URLProtocol {
    // Safety: each test configures this static response before constructing its isolated URLSession.
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var requestedQueries: [String] = []
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if let requestHandler = Self.requestHandler {
            do {
                let (response, data) = try requestHandler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
