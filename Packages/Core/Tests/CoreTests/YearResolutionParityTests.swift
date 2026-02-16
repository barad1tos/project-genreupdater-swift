import Testing
@testable import Core

// MARK: - Year Resolution Parity Tests

@Suite("Year Resolution Parity — Python reference fixtures")
struct YearResolutionParityTests {

    let scorer: YearScorer

    init() throws {
        let config = try FixtureHelpers.loadPythonScoringConfig()
        // Python uses definitiveScoreThreshold=85 (Swift default is 80)
        var yearLogic = YearLogicConfig()
        yearLogic.definitiveScoreThreshold = 85
        scorer = YearScorer(config: config, yearLogic: yearLogic)
    }

    @Test("Year resolution matches Python",
          arguments: try! loadResolutionFixtures())
    func resolutionParity(fixture: ResolutionFixtureCase) {
        // Convert yearScores dict to [ScoredRelease]
        var scored: [ScoredRelease] = []
        for (yearStr, scores) in fixture.yearScores {
            guard let year = Int(yearStr) else { continue }
            for score in scores {
                let candidate = ReleaseCandidate(
                    artist: "Test",
                    album: "Test",
                    year: year,
                    source: .musicBrainz,
                    releaseType: .album,
                    status: .official,
                    country: nil,
                    isReissue: false,
                    mbReleaseGroupID: nil,
                    mbReleaseGroupFirstYear: nil,
                    genre: nil
                )
                scored.append(ScoredRelease(
                    candidate: candidate,
                    totalScore: score,
                    breakdown: ScoreBreakdown()
                ))
            }
        }

        let result = scorer.resolveScores(
            scored,
            existingYear: fixture.existingYearInt
        )

        #expect(
            result.year == fixture.expected.year,
            "[\(fixture.id)] year: got \(String(describing: result.year)), expected \(String(describing: fixture.expected.year))"
        )
        #expect(
            result.isDefinitive == fixture.expected.isDefinitive,
            "[\(fixture.id)] isDefinitive: got \(result.isDefinitive), expected \(fixture.expected.isDefinitive)"
        )
        #expect(
            result.confidence == fixture.expected.confidence,
            "[\(fixture.id)] confidence: got \(result.confidence), expected \(fixture.expected.confidence)"
        )
    }
}

private func loadResolutionFixtures() throws -> [ResolutionFixtureCase] {
    try FixtureLoader.load("year_resolution_reference")
}
