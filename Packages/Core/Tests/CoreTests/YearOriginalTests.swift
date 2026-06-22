import Testing
@testable import Core

@Suite("YearScorer - Original Release Parity")
struct YearOriginalTests {
    @Test("Original release preference uses definitive score difference")
    func originalReleasePreferenceUsesDefinitiveScoreDifference() {
        let scorer = YearScorer(editionKeywords: ["remaster"])
        let scored = [
            makeScoredRelease(year: 2020, score: 100, isReissue: true, album: "Album Remastered"),
            makeScoredRelease(year: 1997, score: 89, album: "Album"),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == 1997)
    }

    @Test("Original release preference skips low score earliest candidate")
    func originalReleasePreferenceSkipsLowScoreEarliestCandidate() {
        let scorer = YearScorer(editionKeywords: ["remaster"])
        let scored = [
            makeScoredRelease(year: 2020, score: 90, isReissue: true, album: "Album Remastered"),
            makeScoredRelease(year: 1970, score: 0, album: "Wrong Album"),
            makeScoredRelease(year: 1997, score: 80, album: "Album"),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == 1997)
    }
}

private func makeScoredRelease(
    year: Int,
    score: Int,
    isReissue: Bool = false,
    album: String
) -> ScoredRelease {
    let candidate = ReleaseCandidate(
        artist: "Test",
        album: album,
        year: year,
        source: .musicBrainz,
        isReissue: isReissue
    )
    var breakdown = ScoreBreakdown()
    breakdown.base = score
    return ScoredRelease(
        candidate: candidate,
        totalScore: score,
        breakdown: breakdown
    )
}
