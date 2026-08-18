import Foundation
import Testing
@testable import Core
@testable import Services

extension CandidateAdapterTests {
    @Test("MusicBrainz stops after a matching generic fallback")
    func stopsAfterGenericFallback() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let requestPathComponents = Array(url.pathComponents.dropFirst())

            if requestPathComponents == musicBrainzReleasePathComponents {
                return try (jsonResponse(url: url), Data(#"{"releases":[]}"#.utf8))
            }

            guard requestPathComponents == musicBrainzReleaseGroupPathComponents else {
                throw URLError(.badURL)
            }

            let (_, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)

            let json = if query == "Björk Debut" {
                """
                {
                  "release-groups": [
                    {
                      "id": "rg-debut",
                      "title": "Debut",
                      "first-release-date": "1993-07-05",
                      "primary-type": "Album",
                      "artist-credit": [
                        {
                          "artist": {
                            "id": "artist-bjork",
                            "name": "Björk Guðmundsdóttir",
                            "aliases": [{"name": "Björk"}]
                          }
                        }
                      ]
                    }
                  ]
                }
                """
            } else {
                #"{"release-groups":[]}"#
            }
            return try (jsonResponse(url: url), Data(json.utf8))
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

        #expect(candidates.map(\.mbReleaseGroupID) == ["rg-debut"])
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"Björk\" AND releasegroup:\"Debut\"",
            "Björk Debut",
        ])
    }

    @Test("MusicBrainz filters generic misses before album-only fallback")
    func filtersAlbumResults() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let requestPathComponents = Array(url.pathComponents.dropFirst())

            if requestPathComponents == musicBrainzReleasePathComponents {
                return try (jsonResponse(url: url), Data(#"{"releases":[]}"#.utf8))
            }

            guard requestPathComponents == musicBrainzReleaseGroupPathComponents else {
                throw URLError(.badURL)
            }

            let (_, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)

            let json: String = if query == "AC/DC Powerage" {
                fallbackGroupJSON(
                    releaseGroupID: "rg-wrong",
                    artist: "The Flaming Lips"
                )
            } else if query == "Powerage" {
                fallbackGroupJSON(
                    releaseGroupID: "rg-acdc",
                    artist: "ACDC"
                )
            } else {
                #"{"release-groups":[]}"#
            }
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer {
            APIReleaseCandidateMockURLProtocol.requestHandler = nil
            APIReleaseCandidateMockURLProtocol.requestedQueries = []
        }

        let client = makeMockMusicBrainzClient()
        let candidates = try await client.getReleaseCandidates(
            artist: "AC/DC",
            album: "Powerage",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.mbReleaseGroupID) == ["rg-acdc"])
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"AC/DC\" AND releasegroup:\"Powerage\"",
            "AC/DC Powerage",
            "Powerage",
        ])
    }
}

private func fallbackGroupJSON(releaseGroupID: String, artist: String) -> String {
    """
    {
      "release-groups": [
        {
          "id": "\(releaseGroupID)",
          "title": "Powerage",
          "first-release-date": "1998-11-24",
          "primary-type": "Album",
          "artist-credit": [
            {
              "artist": {
                "id": "artist-id",
                "name": "\(artist)",
                "aliases": []
              }
            }
          ]
        }
      ]
    }
    """
}
