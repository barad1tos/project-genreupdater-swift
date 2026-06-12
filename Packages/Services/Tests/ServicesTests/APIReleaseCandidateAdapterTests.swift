import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("API release candidate adapters", .serialized)
struct APIReleaseCandidateAdapterTests {
    @Test("MusicBrainz returns release candidates from release groups")
    func musicBrainzReleaseCandidates() async throws {
        let client = MusicBrainzClient(
            appName: "GenreUpdaterTests",
            contactEmail: "tests@example.invalid",
            session: makeMockSession(json: """
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
            """)
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
}

private func makeMockSession(json: String) -> URLSession {
    APIReleaseCandidateMockURLProtocol.responseData = Data(json.utf8)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [APIReleaseCandidateMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class APIReleaseCandidateMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
