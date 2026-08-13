import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — artist start year parity")
struct ArtistStartAPITests {
    @Test("Artist start year falls back to Apple Music when MusicBrainz has no activity period")
    func artistStartYearFallsBackToAppleMusic() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistActivityPeriod: (nil, nil)),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(artistStartYear: 1998)
        )

        let year = await orchestrator.getArtistStartYear(normalizedArtist: "Test Artist")

        #expect(year == 1998)
    }

    @Test("Transient provider failure is retried instead of cached")
    func failureIsRetried() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: ArtistActivityService([.failure, .found(1988)]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        let first = await orchestrator.getArtistStartYear(normalizedArtist: "test artist")
        let second = await orchestrator.getArtistStartYear(normalizedArtist: "test artist")

        #expect(first == nil)
        #expect(second == 1988)
    }

    @Test("Confirmed missing artist start is cached")
    func missingStartIsCached() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: ArtistActivityService([.missing, .found(1988)]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache
        )

        let first = await orchestrator.getArtistStartYear(normalizedArtist: "test artist")
        let second = await orchestrator.getArtistStartYear(normalizedArtist: "test artist")

        #expect(first == nil)
        #expect(second == nil)
    }

    @Test("Transient fallback failure is retried instead of cached")
    func fallbackFailureIsRetried() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(artistActivityPeriod: (nil, nil)),
            discogs: MockAPIService(),
            appleMusic: ArtistActivityService([.failure, .found(1998)]),
            cache: cache
        )

        let first = await orchestrator.getArtistStartYear(normalizedArtist: "test artist")
        let second = await orchestrator.getArtistStartYear(normalizedArtist: "test artist")

        #expect(first == nil)
        #expect(second == 1998)
    }
}

private enum ArtistActivityResponse: Sendable {
    case failure
    case missing
    case found(Int)
}

private actor ArtistActivityService: ExternalAPIService {
    private var responses: [ArtistActivityResponse]

    init(_ responses: [ArtistActivityResponse]) {
        self.responses = responses
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        try next()
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        try next().start
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }

    private func next() throws -> (start: Int?, end: Int?) {
        let response = responses.isEmpty ? .missing : responses.removeFirst()
        switch response {
        case .failure:
            throw MockAPIError.intentional
        case .missing:
            return (nil, nil)
        case let .found(year):
            return (year, nil)
        }
    }
}
