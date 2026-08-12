import Foundation
import Testing
@testable import Core
@testable import Services

/// Python _try_alternative_search parity: only an EMPTY standard aggregate
/// earns one retry with the rewritten query.
@Suite("Release candidates — alternative search fallback")
struct SearchStrategyFallbackTests {
    @Test("An empty soundtrack search retries with the movie query")
    func emptySoundtrackSearchRetriesWithMovieQuery() async {
        let recorder = QueryRecorder()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: RecordingAPIService(recorder: recorder),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            configure: { $0.disabledSources = [.discogs, .itunes] }
        )

        _ = await orchestrator.getReleaseCandidates(
            artist: "Hans Zimmer",
            album: "Dune - Original Score",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let queries = await recorder.queries
        #expect(queries.count == 2)
        #expect(queries.last?.artist == "Dune")
        #expect(queries.last?.album == "Dune")
    }

    @Test("A non-empty standard search never retries")
    func nonEmptySearchNeverRetries() async {
        let recorder = QueryRecorder()
        let candidate = ReleaseCandidate(
            artist: "Hans Zimmer",
            album: "Dune - Original Score",
            year: 2021,
            source: .musicBrainz,
            releaseType: .album,
            status: .official,
            country: "US",
            isReissue: false,
            mbReleaseGroupID: nil,
            mbReleaseGroupFirstYear: nil
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: RecordingAPIService(recorder: recorder, candidates: [candidate]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            configure: { $0.disabledSources = [.discogs, .itunes] }
        )

        let result = await orchestrator.getReleaseCandidates(
            artist: "Hans Zimmer",
            album: "Dune - Original Score",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(!result.isEmpty)
        #expect(await recorder.queries.count == 1)
    }

    @Test("A normal-strategy empty search stays a single round")
    func normalEmptySearchStaysSingleRound() async {
        let recorder = QueryRecorder()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: RecordingAPIService(recorder: recorder),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            configure: { $0.disabledSources = [.discogs, .itunes] }
        )

        _ = await orchestrator.getReleaseCandidates(
            artist: "Plain Artist",
            album: "Plain Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(await recorder.queries.count == 1)
    }

    @Test("Various Artists retries album-only")
    func variousArtistsRetriesAlbumOnly() async {
        let recorder = QueryRecorder()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: RecordingAPIService(recorder: recorder),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            configure: { $0.disabledSources = [.discogs, .itunes] }
        )

        _ = await orchestrator.getReleaseCandidates(
            artist: "Various Artists",
            album: "Now 42",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let queries = await recorder.queries
        #expect(queries.count == 2)
        #expect(queries.last?.artist.isEmpty == true)
        #expect(queries.last?.album == "Now 42")
    }

    @Test("Alternative search keeps one UTC scoring year")
    func keepsScoringYear() async throws {
        let beforeUTCNewYear = try utcDate(year: 2026, month: 12, day: 31, hour: 23)
        let afterUTCNewYear = try utcDate(year: 2027, month: 1, day: 1, hour: 1)
        let dates = SequentialDateProvider([beforeUTCNewYear, afterUTCNewYear])
        let candidate = ReleaseCandidate(
            artist: "Hans Zimmer",
            album: "Dune",
            year: 2025,
            source: .itunes,
            releaseType: .album,
            status: .official,
            country: "us"
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: AlternativeCandidateService(candidate: candidate),
            configure: {
                $0.disabledSources = [.musicBrainz, .discogs]
                $0.dateProvider = dates.now
            }
        )

        let result = await orchestrator.getReleaseCandidates(
            artist: "Hans Zimmer",
            album: "Dune - Original Score",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.first?.isReissue == true)
        #expect(dates.readCount == 1)
    }
}

private actor QueryRecorder {
    private(set) var queries: [(artist: String, album: String)] = []

    func record(artist: String, album: String) {
        queries.append((artist, album))
    }
}

private struct RecordingAPIService: ExternalAPIService {
    let recorder: QueryRecorder
    var candidates: [ReleaseCandidate] = []

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
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await recorder.record(artist: artist, album: album)
        return candidates
    }

    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {
        // Stateless test double.
    }
}

private struct AlternativeCandidateService: ExternalAPIService {
    let candidate: ReleaseCandidate

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
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        artist == "Dune" ? [candidate] : []
    }

    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {}
}

private final class SequentialDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        precondition(!dates.isEmpty)
        self.dates = dates
    }

    var readCount: Int {
        lock.withLock { index }
    }

    func now() -> Date {
        lock.withLock {
            defer { index += 1 }
            return dates[min(index, dates.index(before: dates.endIndex))]
        }
    }
}

private func utcDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
}
