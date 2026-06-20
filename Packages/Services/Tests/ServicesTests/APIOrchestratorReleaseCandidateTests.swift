import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator - release candidate collection")
struct APIOrchestratorReleaseCandidateTests {
    @Test("Common legacy initializer labels remain available")
    func commonLegacyInitializerLabelsRemainAvailable() async {
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: MockCacheService(),
            timeout: .seconds(1),
            disabledSources: [.musicBrainz, .discogs, .itunes]
        )

        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.isEmpty)
    }

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

    @Test("Release candidate cache uses cleaned API search album")
    func releaseCandidateCacheUsesCleanedAPISearchAlbum() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, _, _ in
            [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: 2022,
                    source: .musicBrainz
                ),
            ]
        }
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let decoratedResult = await orchestrator.getReleaseCandidates(
            artist: "Karma & Effect",
            album: "\"Survival of the Sickest\" (Bonus Track Version)",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let cleanedResult = await orchestrator.getReleaseCandidates(
            artist: "Karma and Effect",
            album: "Survival of the Sickest",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(decoratedResult == [
            ReleaseCandidate(
                artist: "Karma and Effect",
                album: "Survival of the Sickest",
                year: 2022,
                source: .musicBrainz
            ),
        ])
        #expect(cleanedResult == decoratedResult)
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

    @Test("Release candidate cache separates query context")
    func releaseCandidateCacheSeparatesQueryContext() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, libraryYear, _ in
            [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: libraryYear ?? 0,
                    source: .musicBrainz
                ),
            ]
        }
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
            currentLibraryYear: 2015,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: 2016,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult.map(\.year) == [2015])
        #expect(secondResult.map(\.year) == [2016])
        #expect(await callCounter.count() == 2)
    }

    @Test("Release candidate cache separates earliest added year context")
    func releaseCandidateCacheSeparatesEarliestAddedYearContext() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, _, addedYear in
            [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: addedYear ?? 0,
                    source: .musicBrainz
                ),
            ]
        }
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
            currentLibraryYear: 2016,
            earliestTrackAddedYear: 2020
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: 2016,
            earliestTrackAddedYear: 2021
        )

        #expect(firstResult.map(\.year) == [2020])
        #expect(secondResult.map(\.year) == [2021])
        #expect(await callCounter.count() == 2)
    }

    @Test("Release candidate cache separates delimiter-like artist and album names")
    func releaseCandidateCacheSeparatesDelimiterLikeArtistAndAlbumNames() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let musicBrainz = CountingReleaseCandidateService(callCounter: callCounter) { artist, album, _, _ in
            let year = artist == "A" && album == "B C" ? 2001 : 2002
            return [
                ReleaseCandidate(
                    artist: artist,
                    album: album,
                    year: year,
                    source: .musicBrainz
                ),
            ]
        }
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )

        let firstResult = await orchestrator.getReleaseCandidates(
            artist: "A",
            album: "B:C",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let secondResult = await orchestrator.getReleaseCandidates(
            artist: "A:B",
            album: "C",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(firstResult.map(\.year) == [2001])
        #expect(secondResult.map(\.year) == [2002])
        #expect(await callCounter.count() == 2)
    }

    @Test("Failed release candidate fetch is not cached as empty")
    func failedReleaseCandidateFetchIsNotCachedAsEmpty() async {
        let cache = MockCacheService()
        let callCounter = APICallCounter()
        let expectedCandidate = ReleaseCandidate(
            artist: "In Flames",
            album: "Battles",
            year: 2016,
            source: .musicBrainz
        )
        let musicBrainz = FlakyReleaseCandidateService(
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

        let failedResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let recoveredResult = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Battles",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(failedResult.isEmpty)
        #expect(recoveredResult == [expectedCandidate])
        #expect(await callCounter.count() == 2)
    }
}

private typealias ReleaseCandidateResolver = @Sendable (
    _ artist: String,
    _ album: String,
    _ currentLibraryYear: Int?,
    _ earliestTrackAddedYear: Int?
) -> [ReleaseCandidate]

private struct CountingReleaseCandidateService: ExternalAPIService {
    let callCounter: APICallCounter
    let releaseCandidates: ReleaseCandidateResolver

    init(callCounter: APICallCounter, releaseCandidates: [ReleaseCandidate]) {
        self.callCounter = callCounter
        self.releaseCandidates = { _, _, _, _ in releaseCandidates }
    }

    init(callCounter: APICallCounter, releaseCandidates: @escaping ReleaseCandidateResolver) {
        self.callCounter = callCounter
        self.releaseCandidates = releaseCandidates
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> [ReleaseCandidate] {
        await callCounter.increment()
        return releaseCandidates(artist, album, currentLibraryYear, earliestTrackAddedYear)
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

    func initialize(force _: Bool) async throws {
        // Test double has no external resources to initialize.
    }

    func close() async {
        // Test double has no external resources to release.
    }
}

private struct FlakyReleaseCandidateService: ExternalAPIService {
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
        let callNumber = await callCounter.incrementAndCount()
        if callNumber == 1 {
            throw ReleaseCandidateTestError.transientFailure
        }
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

    func initialize(force _: Bool) async throws {
        // Test double has no external resources to initialize.
    }

    func close() async {
        // Test double has no external resources to release.
    }
}

private enum ReleaseCandidateTestError: Error {
    case transientFailure
}
