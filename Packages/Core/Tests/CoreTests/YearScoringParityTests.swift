import Testing
@testable import Core

// MARK: - Year Scoring Parity Tests

@Suite("Year Scoring Parity — Python reference fixtures")
struct YearScoringParityTests {

    let scorer: YearScorer

    init() throws {
        let config = try FixtureHelpers.loadPythonScoringConfig()
        scorer = YearScorer(config: config)
    }

    // MARK: - Individual Scoring

    @Test("Individual release scoring matches Python",
          arguments: try! loadScoringFixtures().filter { !$0.isRanking })
    func individualScoring(fixture: ScoringFixtureCase) throws {
        let release = try #require(fixture.release, "Missing release in \(fixture.id)")
        let expected = try #require(fixture.expected, "Missing expected in \(fixture.id)")
        let candidate = release.toCandidate()
        let query = fixture.query

        let activityPeriod: (start: Int?, end: Int?)? = {
            if query.artistPeriodStart != nil || query.artistPeriodEnd != nil {
                return (start: query.artistPeriodStart, end: query.artistPeriodEnd)
            }
            return nil
        }()

        let result = scorer.scoreRelease(
            candidate,
            queryArtist: query.artist,
            queryAlbum: query.album,
            artistActivityPeriod: activityPeriod,
            artistCountry: query.artistRegion
        )

        #expect(
            result.totalScore == expected.totalScore,
            "[\(fixture.id)] totalScore: got \(result.totalScore), expected \(expected.totalScore)"
        )
    }

    // MARK: - Ranking

    @Test("Candidate ranking order matches Python",
          arguments: try! loadScoringFixtures().filter(\.isRanking))
    func rankingOrder(fixture: ScoringFixtureCase) throws {
        let candidates = try #require(fixture.candidates, "Missing candidates in \(fixture.id)")
        let expectedRanking = try #require(
            fixture.expectedRanking, "Missing expectedRanking in \(fixture.id)"
        )
        let query = fixture.query

        let activityPeriod: (start: Int?, end: Int?)? = {
            if query.artistPeriodStart != nil || query.artistPeriodEnd != nil {
                return (start: query.artistPeriodStart, end: query.artistPeriodEnd)
            }
            return nil
        }()

        var scored: [(id: String, score: Int)] = []
        for candidateFixture in candidates {
            let candidate = candidateFixture.release.toCandidate()
            let result = scorer.scoreRelease(
                candidate,
                queryArtist: query.artist,
                queryAlbum: query.album,
                artistActivityPeriod: activityPeriod,
                artistCountry: query.artistRegion
            )
            scored.append((id: candidateFixture.release.source, score: result.totalScore))
        }

        // Sort descending by score (same as Python)
        let actualRanking = scored
            .sorted { $0.score > $1.score }
            .map(\.id)

        #expect(
            actualRanking == expectedRanking,
            "[\(fixture.id)] ranking mismatch"
        )
    }
}

private func loadScoringFixtures() throws -> [ScoringFixtureCase] {
    try FixtureLoader.load("year_scoring_reference")
}
