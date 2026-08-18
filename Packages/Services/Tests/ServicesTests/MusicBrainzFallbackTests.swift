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

            let json = if query == "björk Debut" {
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
            artist: "björk",
            album: "Debut",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.mbReleaseGroupID) == ["rg-debut"])
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"björk\" AND releasegroup:\"Debut\"",
            "björk Debut",
        ])
    }

    @Test("MusicBrainz rejects punctuation-colliding artist credits")
    func rejectsPunctuationCollision() async throws {
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

        #expect(candidates.isEmpty)
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"AC/DC\" AND releasegroup:\"Powerage\"",
            "AC/DC Powerage",
            "Powerage",
        ])
    }

    @Test("MusicBrainz accepts an exact punctuation-bearing artist credit")
    func acceptsExactPunctuation() async throws {
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
            let json = query == "Powerage"
                ? fallbackGroupJSON(releaseGroupID: "rg-acdc", artist: "AC/DC")
                : #"{"release-groups":[]}"#
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer {
            APIReleaseCandidateMockURLProtocol.requestHandler = nil
            APIReleaseCandidateMockURLProtocol.requestedQueries = []
        }

        let candidates = try await makeMockMusicBrainzClient().getReleaseCandidates(
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

    @Test("MusicBrainz continues after canonical lookup failure")
    func canonicalFailureContinues() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let path = Array(url.pathComponents.dropFirst())
            if path == musicBrainzReleasePathComponents {
                return try (jsonResponse(url: url), Data(#"{"releases":[]}"#.utf8))
            }
            if path == ["ws", "2", "artist"] {
                throw URLError(.timedOut)
            }

            let (_, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)
            let json = query == "молчат дома Этажи"
                ? fallbackGroupJSON(releaseGroupID: "rg-etazhi", artist: "Молчат Дома")
                : #"{"release-groups":[]}"#
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer { resetFallbackMock() }

        let candidates = try await makeMockMusicBrainzClient().getReleaseCandidates(
            artist: "молчат дома",
            album: "Этажи",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.mbReleaseGroupID) == ["rg-etazhi"])
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"молчат дома\" AND releasegroup:\"Этажи\"",
            "молчат дома Этажи",
        ])
    }

    @Test("MusicBrainz continues after precise search failure")
    func preciseFailureContinues() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let path = Array(url.pathComponents.dropFirst())
            if path == musicBrainzReleasePathComponents {
                return try (jsonResponse(url: url), Data(#"{"releases":[]}"#.utf8))
            }

            let (_, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)
            if query == "artist:\"artist\" AND releasegroup:\"Album\"" {
                throw URLError(.timedOut)
            }
            let json = query == "artist Album"
                ? fallbackGroupJSON(releaseGroupID: "rg-generic", artist: "Artist")
                : #"{"release-groups":[]}"#
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer { resetFallbackMock() }

        let candidates = try await makeMockMusicBrainzClient().getReleaseCandidates(
            artist: "artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.mbReleaseGroupID) == ["rg-generic"])
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"artist\" AND releasegroup:\"Album\"",
            "artist Album",
        ])
    }

    @Test("MusicBrainz continues from failed generic search to album-only search")
    func genericFailureContinues() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let path = Array(url.pathComponents.dropFirst())
            if path == musicBrainzReleasePathComponents {
                return try (jsonResponse(url: url), Data(#"{"releases":[]}"#.utf8))
            }

            let (_, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)
            if query == "artist Album" {
                throw URLError(.timedOut)
            }
            let json = query == "Album"
                ? fallbackGroupJSON(releaseGroupID: "rg-album", artist: "Artist")
                : #"{"release-groups":[]}"#
            return try (jsonResponse(url: url), Data(json.utf8))
        }
        defer { resetFallbackMock() }

        let candidates = try await makeMockMusicBrainzClient().getReleaseCandidates(
            artist: "artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.mbReleaseGroupID) == ["rg-album"])
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"artist\" AND releasegroup:\"Album\"",
            "artist Album",
            "Album",
        ])
    }

    @Test("MusicBrainz surfaces an earlier failure when later searches are empty")
    func failedFallbackIsNotNotFound() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            let (url, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)
            if query == "artist Album" {
                throw URLError(.timedOut)
            }
            return try (jsonResponse(url: url), Data(#"{"release-groups":[]}"#.utf8))
        }
        defer { resetFallbackMock() }

        do {
            _ = try await makeMockMusicBrainzClient().getReleaseCandidates(
                artist: "artist",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            Issue.record("Expected the transport failure to remain observable")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Expected URLError.timedOut, got \(error)")
        }

        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"artist\" AND releasegroup:\"Album\"",
            "artist Album",
            "Album",
        ])
    }

    @Test("MusicBrainz cancellation does not start a successor search")
    func cancellationStopsFallback() async throws {
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            let (url, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)
            if query == "artist Album" {
                throw CancellationError()
            }
            return try (jsonResponse(url: url), Data(#"{"release-groups":[]}"#.utf8))
        }
        defer { resetFallbackMock() }

        do {
            _ = try await makeMockMusicBrainzClient().getReleaseCandidates(
                artist: "artist",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"artist\" AND releasegroup:\"Album\"",
            "artist Album",
        ])
    }

    @Test("MusicBrainz observes cancellation after an empty response")
    func cancellationAfterEmpty() async throws {
        let transition = EventCounter()
        let gate = SearchTransitionGate()
        APIReleaseCandidateMockURLProtocol.requestedQueries = []
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            let (url, query) = try musicBrainzQuery(from: request)
            APIReleaseCandidateMockURLProtocol.requestedQueries.append(query)
            return try (jsonResponse(url: url), Data(#"{"release-groups":[]}"#.utf8))
        }
        defer { resetFallbackMock() }

        let client = makeMockMusicBrainzClient().withTestHooks(.init(
            beforeSearchTransition: {
                transition.record()
                await gate.wait()
            }
        ))
        let lookup = Task<[ReleaseCandidate], any Error> {
            try await client.getReleaseCandidates(
                artist: "artist",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }

        #expect(await transition.wait(for: 1))
        lookup.cancel()
        await gate.open()

        do {
            _ = try await taskValue(lookup, timeout: .milliseconds(100))
            Issue.record("Expected cancellation after the empty response")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected prompt CancellationError, got \(error)")
        }
        #expect(APIReleaseCandidateMockURLProtocol.requestedQueries == [
            "artist:\"artist\" AND releasegroup:\"Album\"",
        ])
    }

    @Test(
        "MusicBrainz propagates release-detail cancellation",
        arguments: [DetailCancellation.task, .transport]
    )
    func releaseDetailCancellation(_ cancellation: DetailCancellation) async throws {
        APIReleaseCandidateMockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let path = Array(url.pathComponents.dropFirst())
            if path == musicBrainzReleasePathComponents {
                switch cancellation {
                case .task:
                    throw CancellationError()
                case .transport:
                    throw URLError(.cancelled)
                }
            }
            return try (
                jsonResponse(url: url),
                Data(fallbackGroupJSON(releaseGroupID: "rg-1", artist: "Artist").utf8)
            )
        }
        defer { resetFallbackMock() }

        do {
            _ = try await makeMockMusicBrainzClient().getReleaseCandidates(
                artist: "Artist",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            Issue.record("Expected release-detail cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}

enum DetailCancellation: Sendable {
    case task
    case transport
}

private func resetFallbackMock() {
    APIReleaseCandidateMockURLProtocol.requestHandler = nil
    APIReleaseCandidateMockURLProtocol.requestedQueries = []
}

private actor SearchTransitionGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
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
