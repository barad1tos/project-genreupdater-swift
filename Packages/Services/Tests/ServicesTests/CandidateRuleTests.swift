import Foundation
import Testing
@testable import Services

extension CandidateAdapterTests {
    @Test("Configured reissue evidence classifies Discogs candidates")
    func configuredReissueEvidence() async throws {
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let json = """
            {
              "results": [{
                "id": 7,
                "title": "Test Artist - Test Album (Anniversary)",
                "year": 2020,
                "type": "release",
                "country": "US",
                "format": ["Album"]
              }]
            }
            """
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer { APIReleaseCandidateMockURLProtocol.requestHandler = nil }

        let client = DiscogsClient(
            token: "test-token",
            session: makeMockSession(json: "{}")
        ).withReissueKeywords(["anniversary"])
        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.first?.isReissue == true)
    }

    @Test("Empty reissue evidence disables built-in classification")
    func emptyReissueEvidence() async throws {
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let json = """
            {
              "results": [{
                "id": 8,
                "title": "Test Artist - Test Album (Remastered)",
                "year": 2020,
                "type": "release",
                "country": "US",
                "format": ["Album"]
              }]
            }
            """
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer { APIReleaseCandidateMockURLProtocol.requestHandler = nil }

        let client = DiscogsClient(
            token: "test-token",
            session: makeMockSession(json: "{}")
        ).withReissueKeywords([])
        let candidates = try await client.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.first?.isReissue == false)
    }
}
