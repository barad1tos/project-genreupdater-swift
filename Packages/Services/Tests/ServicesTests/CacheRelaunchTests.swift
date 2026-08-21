import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Provider cache relaunch")
struct CacheRelaunchTests {
    @Test("Raw responses survive relaunch without another network request")
    func rawCachePersists() async throws {
        let fixture = try CacheFileFixture()
        defer { fixture.cleanup() }
        let requestURL = try #require(MusicBrainzClient.buildReleaseGroupSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        ))
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

        do {
            let cache = try await fixture.openCache()
            let rawCache = RawAPIRequestCache(cache: cache, ttl: 3600)
            let relaunchedResult = try await rawCache.data(api: "musicbrainz", url: requestURL) {
                await counter.increment()
                return Data("{\"release-groups\":[]}".utf8)
            }

            #expect(relaunchedResult == expectedPayload)
            #expect(await counter.count() == 1)
        }
    }

    @Test("Release candidates survive relaunch without another provider lookup")
    func candidateCachePersists() async throws {
        let fixture = try CacheFileFixture()
        defer { fixture.cleanup() }
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

        do {
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
        defer { fixture.cleanup() }
        let counter = APICallCounter()
        let sourceResult = YearResult(
            year: 1984,
            isDefinitive: true,
            confidence: 93,
            rawScore: 117,
            yearScores: [1984: 93]
        )
        let expectedResult = YearResult(
            year: 1984,
            isDefinitive: false,
            confidence: 93,
            rawScore: 93,
            yearScores: [1984: 93]
        )

        do {
            let cache = try await fixture.openCache()
            let orchestrator = yearOrchestrator(
                cache: cache,
                counter: counter,
                result: sourceResult
            )
            let result = await albumYear(from: orchestrator)

            #expect(result == expectedResult)
            let cachedResult = try #require(await cachedYear(in: cache))
            #expect(cachedResult.metadata["rawScore"] == "117")
            #expect(cachedResult.metadata["isDefinitive"] == "true")
            try await cache.syncToDisk()
        }

        do {
            let cache = try await fixture.openCache()
            let cachedResult = try #require(await cachedYear(in: cache))
            #expect(cachedResult.metadata["rawScore"] == "117")
            #expect(cachedResult.metadata["isDefinitive"] == "true")
            let orchestrator = yearOrchestrator(
                cache: cache,
                counter: counter,
                result: YearResult(
                    year: 2024,
                    confidence: 41,
                    rawScore: 52,
                    yearScores: [2024: 41]
                )
            )
            let relaunchedResult = await albumYear(from: orchestrator)

            #expect(relaunchedResult == expectedResult)
            #expect(await counter.count() == 1)
        }
    }

    private func yearOrchestrator(
        cache: any CacheService,
        counter: APICallCounter,
        result: YearResult
    ) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: CountingAPIService(
                callCounter: counter,
                yearResult: result
            ),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        )
    }

    private func cachedYear(in cache: any CacheService) async -> CachedAPIResult? {
        await cache.getCachedAPIResult(
            artist: "iron maiden",
            album: "powerslave",
            source: APISource.musicBrainz.rawValue
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

    func cleanup() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove provider cache fixture: \(error)")
        }
    }
}
