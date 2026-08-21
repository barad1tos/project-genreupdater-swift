import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Provider cache relaunch")
struct CacheRelaunchTests {
    @Test("Raw responses survive relaunch without another network request")
    func rawCachePersists() async throws {
        let fixture = try CacheFileFixture()
        defer { fixture.remove() }
        let requestURL = try #require(
            URL(string: "https://musicbrainz.org/ws/2/release-group?query=releasegroup%3A%22Powerslave%22")
        )
        let expectedPayload = Data("{\"release-groups\":[{\"id\":\"powerslave-1984\"}]}".utf8)
        let counter = APICallCounter()

        do {
            let cache = try await fixture.openCache()
            let rawCache = RawAPIRequestCache(cache: cache, ttl: 3600)
            let result = try await rawCache.data(api: "musicbrainz", url: requestURL) {
                await counter.increment()
                return expectedPayload
            }

            #expect(result == expectedPayload)
            try await cache.syncToDisk()
        }

        let cache = try await fixture.openCache()
        let rawCache = RawAPIRequestCache(cache: cache, ttl: 3600)
        let relaunchedResult = try await rawCache.data(api: "musicbrainz", url: requestURL) {
            await counter.increment()
            return Data("{\"release-groups\":[]}".utf8)
        }

        #expect(relaunchedResult == expectedPayload)
        #expect(await counter.count() == 1)
    }

    @Test("Release candidates survive relaunch without another provider lookup")
    func candidateCachePersists() async throws {
        let fixture = try CacheFileFixture()
        defer { fixture.remove() }
        let expectedCandidate = ReleaseCandidate(
            artist: "Iron Maiden",
            album: "Powerslave",
            year: 1984,
            source: .musicBrainz,
            releaseType: .album,
            status: .official,
            country: "GB",
            isReissue: false,
            mbReleaseGroupID: "powerslave-1984",
            mbReleaseGroupFirstYear: 1984,
            genre: "Heavy Metal"
        )
        let counter = APICallCounter()

        do {
            let cache = try await fixture.openCache()
            let orchestrator = candidateOrchestrator(
                cache: cache,
                counter: counter,
                candidate: expectedCandidate
            )

            let result = await orchestrator.getReleaseCandidates(
                artist: expectedCandidate.artist,
                album: expectedCandidate.album,
                currentLibraryYear: 2000,
                earliestTrackAddedYear: 2005
            )

            #expect(result == [expectedCandidate])
            try await cache.syncToDisk()
        }

        let cache = try await fixture.openCache()
        let orchestrator = candidateOrchestrator(
            cache: cache,
            counter: counter,
            candidate: ReleaseCandidate(
                artist: expectedCandidate.artist,
                album: expectedCandidate.album,
                year: 2024,
                source: .musicBrainz
            )
        )
        let relaunchedResult = await orchestrator.getReleaseCandidates(
            artist: expectedCandidate.artist,
            album: expectedCandidate.album,
            currentLibraryYear: 2000,
            earliestTrackAddedYear: 2005
        )

        #expect(relaunchedResult == [expectedCandidate])
        #expect(await counter.count() == 1)
    }

    private func candidateOrchestrator(
        cache: any CacheService,
        counter: APICallCounter,
        candidate: ReleaseCandidate
    ) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: CountingReleaseCandidateService(
                callCounter: counter,
                releaseCandidates: [candidate]
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )
    }

    @Test("Album years survive relaunch without another provider lookup")
    func yearCachePersists() async throws {
        let fixture = try CacheFileFixture()
        defer { fixture.remove() }
        let counter = APICallCounter()

        do {
            let cache = try await fixture.openCache()
            let orchestrator = yearOrchestrator(
                cache: cache,
                counter: counter,
                year: 1984
            )
            let result = await albumYear(from: orchestrator)

            #expect(result.year == 1984)
            #expect(result.confidence == 93)
            try await cache.syncToDisk()
        }

        let cache = try await fixture.openCache()
        let orchestrator = yearOrchestrator(
            cache: cache,
            counter: counter,
            year: 2024
        )
        let relaunchedResult = await albumYear(from: orchestrator)

        #expect(relaunchedResult.year == 1984)
        #expect(relaunchedResult.confidence == 93)
        #expect(await counter.count() == 1)
    }

    private func yearOrchestrator(
        cache: any CacheService,
        counter: APICallCounter,
        year: Int
    ) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: CountingAPIService(
                callCounter: counter,
                yearResult: YearResult(
                    year: year,
                    isDefinitive: true,
                    confidence: 93,
                    yearScores: [year: 93]
                )
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )
    }

    private func albumYear(from orchestrator: APIOrchestrator) async -> YearResult {
        await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
    }
}

private struct CacheFileFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = directory.appendingPathComponent("provider-cache.db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func openCache() async throws -> GRDBCacheService {
        let cache = try GRDBCacheService(
            databasePath: databaseURL.path,
            defaultGenericTTL: 3600,
            apiResultTTL: 3600
        )
        try await cache.initialize()
        return cache
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
