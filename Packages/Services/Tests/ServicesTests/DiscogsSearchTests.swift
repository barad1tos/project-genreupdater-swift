import Foundation
import Testing
@testable import Core

extension DiscogsClientRequestTests {
    @Test("getReleaseCandidates continues after matching rows have no usable year")
    func releaseCandidatesContinueAfterUnusableRows() async throws {
        let configuration = DiscogsSearchConfig(detailLookupLimit: 0)
        let lookup = try await getReleaseCandidates(configuration: configuration) { url in
            switch searchQueryValue("q", in: url) {
            case nil:
                return try makeDiscogsJSONResponse(url: url, json: missingYearSearchJSON)
            case "Iron Maiden Powerslave":
                return try makeDiscogsJSONResponse(url: url, json: matchingSearchJSON)
            default:
                Issue.record("Unexpected Discogs fallback request: \(url.absoluteString)")
                return try makeDiscogsJSONResponse(url: url, json: emptySearchJSON)
            }
        }

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(lookup.requests.count == 2)
    }

    @Test("Unrelated rows do not consume the shared detail lookup budget")
    func unrelatedRowsPreserveDetailBudget() async throws {
        let configuration = DiscogsSearchConfig(detailLookupLimit: 1)
        let lookup = try await getReleaseCandidates(configuration: configuration) { url in
            switch url.path {
            case candidateSearchPath where searchQueryValue("artist", in: url) != nil:
                return try makeDiscogsJSONResponse(url: url, json: unrelatedMissingYearJSON)
            case candidateSearchPath where searchQueryValue("q", in: url) != nil:
                return try makeDiscogsJSONResponse(url: url, json: missingYearSearchJSON)
            case candidateReleasePath:
                return try makeDiscogsJSONResponse(url: url, json: releaseDetailJSON)
            default:
                Issue.record("Unexpected Discogs request: \(url.absoluteString)")
                return try makeDiscogsJSONResponse(url: url, json: emptySearchJSON)
            }
        }

        #expect(lookup.candidates.map(\.year) == [1984])
        #expect(candidateReleasePaths(from: lookup.requests) == [candidateReleasePath])
    }

    @Test("Structured Discogs titles reject a mismatched artist prefix")
    func structuredArtistMismatch() async throws {
        let lookup = try await getReleaseCandidates { url in
            if searchQueryValue("artist", in: url) != nil || searchQueryValue("q", in: url) != nil {
                return try makeDiscogsJSONResponse(url: url, json: emptySearchJSON)
            }
            return try makeDiscogsJSONResponse(url: url, json: structuredArtistMismatchJSON)
        }

        #expect(lookup.candidates.isEmpty)
        #expect(lookup.requests.count == 3)
    }
}

private func searchQueryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func candidateReleasePaths(from requests: [URLRequest]) -> [String] {
    requests.compactMap { $0.url?.path }
        .filter { $0.hasPrefix(candidateReleasePath) }
}

private let candidateSearchPath = makeDiscogsTestPath("database", "search")
private let candidateReleasePath = makeDiscogsTestPath("releases", "42")

private let emptySearchJSON = """
{"results":[]}
"""

private let matchingSearchJSON = """
{"results":[{"id":42,"type":"release","title":"Iron Maiden - Powerslave","year":1984}]}
"""

private let missingYearSearchJSON = """
{"results":[{"id":42,"type":"release","title":"Iron Maiden - Powerslave","year":null}]}
"""

private let unrelatedMissingYearJSON = """
{"results":[{"id":900,"type":"release","title":"Powerwolf - Powerslave","year":null}]}
"""

private let structuredArtistMismatchJSON = """
{"results":[{"id":901,"type":"release","title":"Powerwolf - Iron Maiden Powerslave","year":2021}]}
"""

private let releaseDetailJSON = """
{"id":42,"title":"Powerslave","year":1984,"released":null}
"""
