import Foundation
import Testing
@testable import Core
@testable import Services

extension DiscogsClientRequestTests {
    @Test("getAlbumYear defers release details until release-scoped search")
    func getAlbumYearDefersReleaseDetailsUntilReleaseSearch() async throws {
        let lookup = try await getFallbackAlbumYear { url in
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

    @Test("getAlbumYear tolerates release-search HTTP failures")
    func getAlbumYearToleratesReleaseSearchHTTPFailures() async throws {
        let lookup = try await getFallbackAlbumYear { url in
            switch url.path {
            case discogsSearchPath where queryValue("type", in: url) == "master":
                return try makeDiscogsJSONResponse(url: url, json: discogsMissingCanonicalSearchYearJSON)
            case discogsSearchPath where queryValue("type", in: url) == "release":
                return try makeDiscogsJSONResponse(url: url, json: "{}", statusCode: 500)
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
            _ = try await getFallbackAlbumYear { url in
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
        let lookup = try await getFallbackReleaseCandidates { url in
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
        let lookup = try await getFallbackReleaseCandidates { url in
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
        let lookup = try await getFallbackReleaseCandidates { url in
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
            _ = try await getFallbackReleaseCandidates { url in
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

    private func getFallbackAlbumYear(
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

    private func getFallbackReleaseCandidates(
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

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
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
