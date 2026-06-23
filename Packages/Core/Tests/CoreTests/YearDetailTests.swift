import Foundation
import Testing
@testable import Core

@Suite("Year candidate details")
struct YearDetailTests {
    @Test("Release details keep official original year ahead of promotional reissue")
    func releaseDetailsKeepOriginalYearAhead() {
        let scorer = YearScorer()
        let original = ReleaseCandidate(
            artist: "Test Artist",
            album: "Test Album",
            year: 1998,
            source: .musicBrainz,
            status: .official,
            country: "gb",
            mbReleaseGroupID: "rg-1",
            mbReleaseGroupFirstYear: 1998
        )
        let promotionalReissue = ReleaseCandidate(
            artist: "Test Artist",
            album: "Test Album",
            year: 2020,
            source: .musicBrainz,
            status: .promotional,
            country: "gb",
            isReissue: true,
            mbReleaseGroupID: "rg-1",
            mbReleaseGroupFirstYear: 1998
        )

        let scoredOriginal = scorer.scoreRelease(
            original,
            queryArtist: "Test Artist",
            queryAlbum: "Test Album",
            artistCountry: "gb"
        )
        let scoredReissue = scorer.scoreRelease(
            promotionalReissue,
            queryArtist: "Test Artist",
            queryAlbum: "Test Album",
            artistCountry: "gb"
        )
        let result = scorer.resolveScores([scoredReissue, scoredOriginal])

        #expect(scoredOriginal.totalScore > scoredReissue.totalScore)
        #expect(scoredReissue.breakdown.releaseStatus == scorer.config.statusPromoPenalty)
        #expect(scoredReissue.breakdown.reissuePenalty == scorer.config.reissuePenalty)
        #expect(result.year == 1998)
    }

    @Test("Future winner stays non-definitive when selected")
    func futureWinnerStaysNonDefinitive() {
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let scored = [
            makeScoredRelease(year: calendarYear + 2, score: 100),
            makeScoredRelease(year: calendarYear - 1, score: 70),
        ]

        let result = YearScorer().resolveScores(scored)

        #expect(result.year == calendarYear + 2)
        #expect(result.isDefinitive == false)
        #expect(result.confidence == 100)
    }
}

private func makeScoredRelease(year: Int, score: Int) -> ScoredRelease {
    let candidate = ReleaseCandidate(
        artist: "Test Artist",
        album: "Test Album",
        year: year,
        source: .musicBrainz
    )
    return ScoredRelease(
        candidate: candidate,
        totalScore: score,
        breakdown: ScoreBreakdown()
    )
}
