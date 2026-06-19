import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator - release candidate collection")
struct APIOrchestratorReleaseCandidateTests {
    @Test("collects release candidates in configured source order")
    func collectsReleaseCandidatesInSourceOrder() async {
        let musicBrainz = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 1998,
                source: .musicBrainz
            ),
        ])
        let discogs = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 1999,
                source: .discogs
            ),
        ])
        let appleMusic = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 2001,
                source: .itunes
            ),
        ])

        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(
                preferredAPI: .discogs,
                scriptPriorities: [:]
            )
        }

        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.source) == [.discogs, .musicBrainz, .itunes])
        #expect(candidates.map(\.year) == [1999, 1998, 2001])
    }

    @Test("Release candidate cache skips repeated source requests")
    func releaseCandidateCacheSkipsRepeatedSourceRequests() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let expectedCandidate = ReleaseCandidate(
            artist: "In Flames",
            album: "Battles",
            year: 2016,
            source: .musicBrainz
        )
        let musicBrainz = CountingReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: [expectedCandidate]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: " in flames ",
            album: " battles ",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult == [expectedCandidate])
        #expect(secondResult == [expectedCandidate])
        #expect(await callCounter.count() == 1)
    }

    @Test("Empty release candidate result is cached")
    func emptyReleaseCandidateResultIsCached() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(
            callCounter: callCounter,
            releaseCandidates: []
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        ) {
            $0.negativeResultTTL = 123
        }

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "Unknown Artist",
            album: "Unknown Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult.isEmpty)
        #expect(secondResult.isEmpty)
        #expect(await callCounter.count() == 1)
    }
}

private struct CountingReleaseCandidateService: ExternalAPIService {
    let callCounter: APICallCounter
    let releaseCandidates: [ReleaseCandidate]

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await callCounter.increment()
        return releaseCandidates
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(
        normalizedArtist _: String
    ) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {}
    func close() async {}
}
