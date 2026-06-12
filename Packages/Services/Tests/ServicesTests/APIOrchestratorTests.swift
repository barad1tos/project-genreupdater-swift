import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - APIOrchestratorTests

@Suite("APIOrchestrator — parallel multi-source year aggregation")
struct APIOrchestratorTests {
    @Test("Aggregates results from multiple sources with combined confidence > 80")
    func aggregateResultsFromMultipleSources() async {
        let musicBrainz = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 80,
                yearScores: [1984: 80]
            )
        )
        let discogs = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 75,
                yearScores: [1984: 75]
            )
        )
        let appleMusic = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 70,
                yearScores: [1984: 70]
            )
        )

        let orchestrator = APIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1984)
        #expect(result.confidence > 80)
        #expect(result.isDefinitive == true)
    }

    @Test("Continues when one source fails, returns surviving source result")
    func continuesWhenOneSourceFails() async {
        let musicBrainz = MockAPIService(
            yearResult: YearResult(
                year: 1986,
                confidence: 80,
                yearScores: [1986: 80]
            )
        )
        let discogs = MockAPIService(shouldThrow: true)
        let appleMusic = MockAPIService(shouldThrow: true)

        let orchestrator = APIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Metallica",
            album: "Master of Puppets",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1986)
    }

    @Test("Returns empty result when all sources fail")
    func returnsEmptyWhenAllSourcesFail() async {
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(shouldThrow: true),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Nobody",
            album: "Nothing",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(result.confidence == 0)
    }

    @Test("Handles timeout for slow sources, returns fast source result")
    func handlesTimeoutForSlowSources() async {
        let fastService = MockAPIService(
            yearResult: YearResult(
                year: 2000,
                confidence: 80,
                yearScores: [2000: 80]
            )
        )
        let slowService = MockAPIService(
            yearResult: YearResult(
                year: 2001,
                confidence: 90,
                yearScores: [2001: 90]
            ),
            delay: .seconds(10)
        )

        let orchestrator = APIOrchestrator(
            musicBrainz: fastService,
            discogs: slowService,
            appleMusic: MockAPIService(shouldThrow: true),
            timeout: .milliseconds(200)
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2000)
    }

    @Test("Limits concurrent source calls")
    func limitsConcurrentSourceCalls() async {
        let probe = APIConcurrencyProbe()
        let orchestrator = APIOrchestrator(
            musicBrainz: RecordingAPIService(
                probe: probe,
                yearResult: YearResult(year: 2000, confidence: 60, yearScores: [2000: 60]),
                delay: .milliseconds(50)
            ),
            discogs: RecordingAPIService(
                probe: probe,
                yearResult: YearResult(year: 2001, confidence: 60, yearScores: [2001: 60]),
                delay: .milliseconds(50)
            ),
            appleMusic: RecordingAPIService(
                probe: probe,
                yearResult: YearResult(year: 2002, confidence: 60, yearScores: [2002: 60]),
                delay: .milliseconds(50)
            ),
            timeout: .seconds(1),
            maxConcurrentSourceCalls: 1
        )

        _ = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let maxActive = await probe.maxActive()
        #expect(maxActive == 1)
    }

    @Test("Best year selected by highest combined score across sources")
    func bestYearSelectedByHighestCombinedScore() async {
        // MB returns 1984 (80), DC returns 1985 (60), AM returns 1984 (70)
        // Combined: 1984 = 150, 1985 = 60 => 1984 wins
        let musicBrainz = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 80,
                yearScores: [1984: 80]
            )
        )
        let discogs = MockAPIService(
            yearResult: YearResult(
                year: 1985,
                confidence: 60,
                yearScores: [1985: 60]
            )
        )
        let appleMusic = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 70,
                yearScores: [1984: 70]
            )
        )

        let orchestrator = APIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        // 1984 has combined score 150 (80+70) vs 1985 at 60
        #expect(result.year == 1984)
        // Confidence capped at 100
        #expect(result.confidence == 100)
        #expect(result.isDefinitive == true)
        // yearScores preserves both years
        #expect(result.yearScores[1984] == 150)
        #expect(result.yearScores[1985] == 60)
    }
}

private actor APIConcurrencyProbe {
    private var activeCount = 0
    private var maxActiveCount = 0

    func begin() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }

    func maxActive() -> Int {
        maxActiveCount
    }
}

private struct RecordingAPIService: ExternalAPIService {
    let probe: APIConcurrencyProbe
    let yearResult: YearResult
    let delay: Duration

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await probe.begin()
        try await Task.sleep(for: delay)
        await probe.end()
        return yearResult
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
