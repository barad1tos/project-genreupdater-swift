import Foundation
import Testing
@testable import Core
@testable import Services

extension DiscogsClientRequestTests {
    @Test("getReleaseCandidates uses the fielded release query before generic fallback")
    func releaseCandidatesUseGenericFallback() async throws {
        let lookup = try await getReleaseCandidates { url in
            switch queryValue("q", in: url) {
            case nil:
                return try makeDiscogsJSONResponse(url: url, json: discogsEmptySearchResponseJSON)
            case "Iron Maiden Powerslave":
                return try makeDiscogsJSONResponse(url: url, json: discogsMatchingSearchResponseJSON)
            default:
                Issue.record("Unexpected Discogs fallback request: \(url.absoluteString)")
                return try makeDiscogsJSONResponse(url: url, json: discogsEmptySearchResponseJSON)
            }
        }
        let searchURLs = lookup.requests.compactMap(\.url)

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(searchURLs.map(queryParameters) == [
            [
                "artist": "Iron Maiden",
                "release_title": "Powerslave",
                "type": "release",
                "per_page": "25",
            ],
            [
                "q": "Iron Maiden Powerslave",
                "type": "release",
                "per_page": "25",
            ],
        ])
    }

    @Test("getReleaseCandidates filters album-only fallback results to the requested artist")
    func releaseCandidatesFilterAlbumOnlyFallback() async throws {
        let lookup = try await getReleaseCandidates { url in
            if queryValue("artist", in: url) != nil || queryValue("q", in: url) != nil {
                return try makeDiscogsJSONResponse(url: url, json: discogsEmptySearchResponseJSON)
            }
            return try makeDiscogsJSONResponse(url: url, json: discogsAlbumOnlySearchResponseJSON)
        }
        let searchURLs = lookup.requests.compactMap(\.url)

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(searchURLs.map(queryParameters) == [
            [
                "artist": "Iron Maiden",
                "release_title": "Powerslave",
                "type": "release",
                "per_page": "25",
            ],
            [
                "q": "Iron Maiden Powerslave",
                "type": "release",
                "per_page": "25",
            ],
            [
                "release_title": "Powerslave",
                "type": "release",
                "per_page": "25",
            ],
        ])
    }

    @Test("Discogs search settings control result breadth and detail recovery")
    func releaseCandidatesUseConfiguredSearchLimits() async throws {
        var configuration = DiscogsSearchConfig()
        configuration.resultLimit = 17
        configuration.detailLookupLimit = 2
        let lookup = try await getReleaseCandidates(configuration: configuration) { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(
                    url: url,
                    json: makeDiscogsMissingReleaseSearchResponseJSON(count: 3)
                )
            case _ where url.path.hasPrefix(discogsReleasePathPrefix):
                return try makeDiscogsJSONResponse(url: url, json: discogsReleaseDetailYearResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }
        let searchURL = try #require(lookup.requests.first?.url)

        #expect(queryValue("per_page", in: searchURL) == "17")
        #expect(lookup.candidates.count == 2)
        #expect(releaseDetailPaths(from: lookup.requests).count == 2)
    }

    @Test("Discogs search breadth also applies to direct year lookup")
    func albumYearUsesConfiguredSearchLimit() async throws {
        var configuration = DiscogsSearchConfig()
        configuration.resultLimit = 17
        let lookup = try await getAlbumYear(configuration: configuration) { url in
            try makeAlbumYearReleaseFallbackResponse(
                url: url,
                releaseDetailJSON: discogsReleaseDetailYearResponseJSON
            )
        }

        let searchURLs = lookup.requests.compactMap(\.url).filter { $0.path == discogsSearchPath }
        #expect(searchURLs.count == 2)
        #expect(searchURLs.allSatisfy { queryValue("per_page", in: $0) == "17" })
    }

    @Test("getReleaseCandidates continues after an ordinary search failure")
    func releaseCandidatesContinueAfterFailure() async throws {
        let lookup = try await getReleaseCandidates { url in
            if queryValue("artist", in: url) != nil {
                throw URLError(.timedOut)
            }
            return try makeDiscogsJSONResponse(url: url, json: discogsMatchingSearchResponseJSON)
        }

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(lookup.requests.count == 2)
    }

    @Test("getReleaseCandidates preserves a provider failure when fallbacks are empty")
    func releaseCandidatesPreserveFailure() async {
        let outcome = await releaseCandidateOutcome { url in
            if queryValue("artist", in: url) != nil {
                throw URLError(.timedOut)
            }
            return try makeDiscogsJSONResponse(url: url, json: discogsEmptySearchResponseJSON)
        }

        #expect(outcome.requests.count == 3)
        guard case let .failure(error as URLError) = outcome.result else {
            Issue.record("Expected the first Discogs transport failure")
            return
        }
        #expect(error.code == .timedOut)
    }

    @Test("getReleaseCandidates does not start a fallback after cancellation")
    func releaseCandidatesStopAfterCancellation() async {
        let outcome = await releaseCandidateOutcome { _ in
            throw URLError(.cancelled)
        }

        #expect(outcome.requests.count == 1)
        guard case let .failure(error as URLError) = outcome.result else {
            Issue.record("Expected Discogs cancellation")
            return
        }
        #expect(error.code == .cancelled)
    }

    @Test("getAlbumYear defers release details until release-scoped search")
    func getAlbumYearDefersReleaseDetailsUntilReleaseSearch() async throws {
        let lookup = try await getAlbumYear { url in
            switch url.path {
            case discogsSearchPath where queryValue("type", in: url) == "master":
                return try makeDiscogsJSONResponse(url: url, json: discogsMissingSearchYearResponseJSON)
            case discogsSearchPath where queryValue("type", in: url) == "release":
                return try makeDiscogsJSONResponse(url: url, json: discogsMissingSearchYearResponseJSON)
            case discogsReleaseDetailPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsReleaseDetailYearResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }

        #expect(lookup.result.year == 1984)
        #expect(lookup.requests.map { $0.url?.path } == [
            discogsSearchPath,
            discogsSearchPath,
            discogsReleaseDetailPath,
        ])
    }

    @Test("getAlbumYear propagates release-search HTTP failures")
    func getAlbumYearPropagatesReleaseSearchHTTPFailures() async throws {
        do {
            _ = try await getAlbumYear { url in
                switch url.path {
                case discogsSearchPath where queryValue("type", in: url) == "master":
                    return try makeDiscogsJSONResponse(url: url, json: discogsMissingCanonicalSearchYearJSON)
                case discogsSearchPath where queryValue("type", in: url) == "release":
                    return try makeDiscogsJSONResponse(url: url, json: "{}", statusCode: 500)
                default:
                    throw URLError(.badURL)
                }
            }
            Issue.record("Expected release-search HTTP failure to propagate")
        } catch let error as DiscogsError {
            #expect(error.matches(.httpError(500)))
        }
    }

    @Test("getAlbumYear treats malformed release-search payload as empty")
    func getAlbumYearTreatsMalformedReleaseSearchPayloadAsEmpty() async throws {
        let lookup = try await getAlbumYear { url in
            switch url.path {
            case discogsSearchPath where queryValue("type", in: url) == "master":
                return try makeDiscogsJSONResponse(url: url, json: discogsMissingCanonicalSearchYearJSON)
            case discogsSearchPath where queryValue("type", in: url) == "release":
                return try makeDiscogsJSONResponse(url: url, json: "{")
            default:
                throw URLError(.badURL)
            }
        }

        #expect(lookup.result.year == nil)
        #expect(lookup.requests.map { $0.url?.path } == [discogsSearchPath, discogsSearchPath])
    }

    @Test("getAlbumYear propagates release-search cancellation")
    func getAlbumYearPropagatesReleaseSearchCancellation() async throws {
        do {
            _ = try await getAlbumYear { url in
                switch url.path {
                case discogsSearchPath where queryValue("type", in: url) == "master":
                    return try makeDiscogsJSONResponse(url: url, json: discogsMissingCanonicalSearchYearJSON)
                case discogsSearchPath where queryValue("type", in: url) == "release":
                    throw URLError(.cancelled)
                default:
                    throw URLError(.badURL)
                }
            }
            Issue.record("Expected release-search cancellation to propagate")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }

    @Test("getReleaseCandidates prefers canonical master before release detail")
    func getReleaseCandidatesPrefersCanonicalReleaseBeforeDetail() async throws {
        let lookup = try await getReleaseCandidates { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(
                    url: url,
                    json: discogsMissingReleaseWithCanonicalIDJSON
                )
            case discogsCanonicalPath:
                return try makeDiscogsJSONResponse(url: url, json: discogsReleaseResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(lookup.requests.map { $0.url?.path } == [discogsSearchPath, discogsCanonicalPath])
    }

    @Test("getReleaseCandidates limits release detail recovery lookups")
    func getReleaseCandidatesLimitsReleaseDetailRecoveryLookups() async throws {
        let lookup = try await getReleaseCandidates { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(
                    url: url,
                    json: makeDiscogsMissingReleaseSearchResponseJSON(count: 11)
                )
            case _ where url.path.hasPrefix(discogsReleasePathPrefix):
                return try makeDiscogsJSONResponse(url: url, json: discogsReleaseDetailYearResponseJSON)
            default:
                throw URLError(.badURL)
            }
        }
        let releaseDetailPaths = releaseDetailPaths(from: lookup.requests)

        #expect(lookup.candidates.count == 10)
        #expect(releaseDetailPaths.count == 10)
    }

    @Test("getReleaseCandidates limits failed release detail lookups")
    func getReleaseCandidatesLimitsFailedReleaseDetailLookups() async throws {
        let lookup = try await getReleaseCandidates { url in
            switch url.path {
            case discogsSearchPath:
                return try makeDiscogsJSONResponse(
                    url: url,
                    json: makeDiscogsMissingReleaseSearchResponseJSON(count: 11)
                )
            case _ where url.path.hasPrefix(discogsReleasePathPrefix):
                return try makeDiscogsJSONResponse(url: url, json: "{}", statusCode: 500)
            default:
                throw URLError(.badURL)
            }
        }
        let releaseDetailPaths = releaseDetailPaths(from: lookup.requests)

        #expect(lookup.candidates.isEmpty)
        #expect(releaseDetailPaths.count == 10)
    }

    @Test("getReleaseCandidates propagates release detail cancellation")
    func getReleaseCandidatesPropagatesReleaseDetailCancellation() async throws {
        do {
            _ = try await getReleaseCandidates { url in
                switch url.path {
                case discogsSearchPath:
                    return try makeDiscogsJSONResponse(
                        url: url,
                        json: makeDiscogsMissingReleaseSearchResponseJSON(count: 1)
                    )
                case _ where url.path.hasPrefix(discogsReleasePathPrefix):
                    throw URLError(.cancelled)
                default:
                    throw URLError(.badURL)
                }
            }
            Issue.record("Expected release-detail cancellation to propagate")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }
}

extension DiscogsClientRequestTests {
    private func releaseCandidateOutcome(
        response: @escaping (URL) throws -> (HTTPURLResponse, Data)
    ) async -> (result: Result<[ReleaseCandidate], any Error>, requests: [URLRequest]) {
        let recorder = DiscogsRequestRecorder()
        let session = makeDiscogsMockSession { request in
            recorder.append(request)
            guard let url = request.url else { throw URLError(.badURL) }
            return try response(url)
        }
        defer {
            resetDiscogsMockSession()
            session.invalidateAndCancel()
        }

        do {
            let candidates = try await DiscogsClient(
                token: "test-token-123",
                session: session,
                baseURL: makeDiscogsSandboxBaseURL()
            ).getReleaseCandidates(
                artist: "Iron Maiden",
                album: "Powerslave",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            return (.success(candidates), recorder.snapshot)
        } catch {
            return (.failure(error), recorder.snapshot)
        }
    }
}

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func queryParameters(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .compactMap { item in item.value.map { (item.name, $0) } } ?? [])
}

private func releaseDetailPaths(from requests: [URLRequest]) -> [String] {
    requests.compactMap { $0.url?.path }
        .filter { $0.hasPrefix(discogsReleasePathPrefix) }
}

private func makeDiscogsMissingReleaseSearchResponseJSON(count: Int) -> String {
    let results = (0 ..< count).map { index in
        """
            {
              "id": \(1000 + index),
              "type": "release",
              "title": "Iron Maiden - Powerslave",
              "year": null
            }
        """
    }.joined(separator: ",\n")

    return """
    {
      "pagination": { "page": 1, "pages": 1, "per_page": \(count), "items": \(count) },
      "results": [
    \(results)
      ]
    }
    """
}

private let discogsSearchPath = makeDiscogsTestPath("database", "search")
private let discogsCanonicalPath = makeDiscogsTestPath("masters", "12345")
private let discogsReleaseDetailPath = makeDiscogsTestPath("releases", "42")
private let discogsReleasePathPrefix = makeDiscogsTestPath("releases")

private let discogsEmptySearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 0, "per_page": 25, "items": 0 },
  "results": []
}
"""

private let discogsMatchingSearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 25, "items": 1 },
  "results": [
    {
      "id": 42,
      "type": "release",
      "title": "Iron Maiden - Powerslave",
      "year": 1984
    }
  ]
}
"""

private let discogsAlbumOnlySearchResponseJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 25, "items": 2 },
  "results": [
    {
      "id": 42,
      "type": "release",
      "title": "Iron Maiden (2) - Powerslave",
      "year": 1984
    },
    {
      "id": 43,
      "type": "release",
      "title": "Powerwolf - Powerslave",
      "year": 2021
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

private let discogsMissingReleaseWithCanonicalIDJSON = """
{
  "pagination": { "page": 1, "pages": 1, "per_page": 5, "items": 1 },
  "results": [
    {
      "id": 42,
      "type": "release",
      "master_id": 12345,
      "title": "Iron Maiden - Powerslave",
      "year": null
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

private let discogsReleaseResponseJSON = """
{
  "id": 12345,
  "title": "Powerslave",
  "year": 1984,
  "genres": ["Rock"],
  "styles": ["Heavy Metal"]
}
"""
