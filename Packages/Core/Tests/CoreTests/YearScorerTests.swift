import Foundation
import Testing
@testable import Core

// MARK: - YearScorer Tests

@Suite("YearScorer — Multi-Factor Release Scoring")
struct YearScorerScoringTests {

    let scorer = YearScorer()

    // MARK: - Base Score

    @Test("Base score is always applied")
    func baseScore() {
        let candidate = makeCandidate(artist: "Test", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Test", queryAlbum: "Test")
        #expect(result.breakdown.base == 50)
    }

    // MARK: - Artist Match

    @Test("Exact artist match gives bonus")
    func artistExactMatch() {
        let candidate = makeCandidate(artist: "Radiohead", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Radiohead", queryAlbum: "Test")
        #expect(result.breakdown.artistMatch == 30)
    }

    @Test("Fuzzy artist match gives bonus")
    func artistFuzzyMatch() {
        let candidate = makeCandidate(artist: "The Beatles", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Beatles", queryAlbum: "Test")
        // After normalization: "beatles" == "beatles" → exact match bonus
        #expect(result.breakdown.artistMatch == 30)
    }

    @Test("Artist substring gives penalty")
    func artistSubstring() {
        let candidate = makeCandidate(artist: "Radiohead Orchestra", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Radiohead", queryAlbum: "Test")
        // "radiohead" is substring of "radiohead orchestra" → substring penalty
        #expect(result.breakdown.artistMatch == -20)
    }

    @Test("Mismatched artist gives heavy penalty")
    func artistMismatch() {
        let candidate = makeCandidate(artist: "Pink Floyd", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Iron Maiden", queryAlbum: "Test")
        #expect(result.breakdown.artistMatch == -60)
    }

    // MARK: - Album Match

    @Test("Perfect album match gives highest bonus")
    func albumPerfectMatch() {
        let candidate = makeCandidate(artist: "X", album: "OK Computer", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "OK Computer")
        #expect(result.breakdown.albumMatch == 40)
    }

    @Test("Album variant gives variant bonus")
    func albumVariant() {
        let candidate = makeCandidate(artist: "X", album: "OK Computer (Remastered)", year: 2017)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "OK Computer")
        // After album comparison normalization: both become "ok computer" → exact match
        #expect(result.breakdown.albumMatch == 25)
    }

    @Test("Unrelated album gives penalty")
    func albumUnrelated() {
        let candidate = makeCandidate(artist: "X", album: "The Bends", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "Kid A")
        #expect(result.breakdown.albumMatch == -50)
    }

    // MARK: - Release Type

    @Test("Album type gets bonus")
    func releaseTypeAlbum() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .album)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == 10)
    }

    @Test("EP type gets penalty")
    func releaseTypeEP() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .ep)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == -5)
    }

    @Test("Compilation type gets heavier penalty")
    func releaseTypeCompilation() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .compilation)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == -15)
    }

    // MARK: - Release Status

    @Test("Official status gets bonus")
    func statusOfficial() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, status: .official)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseStatus == 10)
    }

    @Test("Bootleg status gets penalty")
    func statusBootleg() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, status: .bootleg)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseStatus == -30)
    }

    // MARK: - Reissue Penalty

    @Test("Reissue gets penalty")
    func reissuePenalty() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2020, isReissue: true)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.reissuePenalty == -20)
    }

    @Test("Non-reissue gets no penalty")
    func noReissuePenalty() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2020, isReissue: false)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.reissuePenalty == 0)
    }

    // MARK: - Year Difference

    @Test("No year diff when no reference")
    func yearDiffNoReference() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.yearDiff == 0)
    }

    @Test("Year diff penalty scales with distance")
    func yearDiffPenalty() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2005)
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            currentYear: 2000
        )
        // diff=5, 1-year grace: penalty = -5 × (5-1) = -20
        #expect(result.breakdown.yearDiff == -20)
    }

    @Test("Year diff penalty capped at max")
    func yearDiffCapped() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2020)
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            currentYear: 2000
        )
        // diff=20, 1-year grace: penalty = -5 × 19 = -95, capped at -50
        #expect(result.breakdown.yearDiff == -50)
    }

    @Test("Year diff uses MB release group first year as reference")
    func yearDiffUsesRGYear() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 2020,
            mbReleaseGroupFirstYear: 2000
        )
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            currentYear: 2015
        )
        // Uses mbReleaseGroupFirstYear (2000), diff=20, capped at -50
        #expect(result.breakdown.yearDiff == -50)
    }

    // MARK: - Artist Period

    @Test("Year before artist start gets penalty")
    func yearBeforeArtistStart() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 1990)
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistActivityPeriod: (start: 2000, end: 2020)
        )
        #expect(result.breakdown.artistPeriod == -30)
    }

    @Test("Year after artist end gets penalty")
    func yearAfterArtistEnd() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2025)
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistActivityPeriod: (start: 2000, end: 2020)
        )
        #expect(result.breakdown.artistPeriod == -15)
    }

    @Test("Year near artist start gets bonus")
    func yearNearArtistStart() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2001)
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistActivityPeriod: (start: 2000, end: 2020)
        )
        #expect(result.breakdown.artistPeriod == 10)
    }

    // MARK: - Country

    @Test("Country artist match gives bonus")
    func countryArtistMatch() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, country: "GB")
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistCountry: "GB"
        )
        #expect(result.breakdown.country == 5)
    }

    @Test("Major market country gives smaller bonus")
    func countryMajorMarket() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, country: "US")
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistCountry: "JP"
        )
        #expect(result.breakdown.country == 3)
    }

    @Test("Unknown country gives no bonus")
    func countryNone() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, country: nil)
        let result = scorer.scoreRelease(
            candidate, queryArtist: "X", queryAlbum: "X"
        )
        #expect(result.breakdown.country == 0)
    }

    // MARK: - Source Reliability

    @Test("MusicBrainz source gives highest bonus")
    func sourceMB() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 2000, source: .musicBrainz
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.sourceReliability == 10)
    }

    @Test("Discogs source gives moderate bonus")
    func sourceDiscogs() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 2000, source: .discogs
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.sourceReliability == 5)
    }

    // MARK: - Release Group Match

    @Test("MB release group with matching first year gives full bonus")
    func releaseGroupMatchFull() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 1997,
            mbReleaseGroupID: "abc-123",
            mbReleaseGroupFirstYear: 1997
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseGroupMatch == 20)
    }

    @Test("MB release group with different first year gives half bonus")
    func releaseGroupMatchHalf() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 2017,
            mbReleaseGroupID: "abc-123",
            mbReleaseGroupFirstYear: 1997
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseGroupMatch == 10)
    }

    // MARK: - Total Score Integration

    @Test("High-quality match produces high total score")
    func highQualityMatch() {
        let candidate = ReleaseCandidate(
            artist: "Radiohead",
            album: "OK Computer",
            year: 1997,
            source: .musicBrainz,
            releaseType: .album,
            status: .official,
            country: "GB",
            isReissue: false,
            mbReleaseGroupID: "abc",
            mbReleaseGroupFirstYear: 1997
        )
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "Radiohead",
            queryAlbum: "OK Computer",
            artistActivityPeriod: (start: 1992, end: nil),
            artistCountry: "GB"
        )
        // base(50) + artist(30) + album(40) + RG(20) + type(10) + status(10) + country(5) + source(10) = 175
        #expect(result.totalScore >= 150)
    }

    @Test("Low-quality match produces low total score")
    func lowQualityMatch() {
        let candidate = ReleaseCandidate(
            artist: "Various Artists",
            album: "Greatest Hits Vol. 3",
            year: 2020,
            source: .itunes,
            releaseType: .compilation,
            status: .other,
            isReissue: true
        )
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "Radiohead",
            queryAlbum: "OK Computer",
            currentYear: 1997
        )
        // Heavy penalties: artist mismatch, album unrelated, compilation, reissue, year diff
        #expect(result.totalScore < 0)
    }

    // MARK: - Soundtrack Compensation

    @Test("Soundtrack album compensates artist mismatch")
    func soundtrackCompensation() {
        let candidate = makeCandidate(
            artist: "Hans Zimmer",
            album: "Inception (Original Motion Picture Soundtrack)",
            year: 2010,
            releaseType: .soundtrack
        )
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "Various Artists",
            queryAlbum: "Inception (Original Motion Picture Soundtrack)"
        )
        #expect(result.breakdown.soundtrackCompensation == 75)
    }

    @Test("Non-soundtrack does not get compensation")
    func noSoundtrackCompensation() {
        let candidate = makeCandidate(artist: "X", album: "Album", year: 2000, releaseType: .album)
        let result = scorer.scoreRelease(candidate, queryArtist: "Y", queryAlbum: "Album")
        #expect(result.breakdown.soundtrackCompensation == 0)
    }
}

// MARK: - Score Resolution Tests

@Suite("YearScorer — Score Resolution")
struct YearScorerResolutionTests {

    let scorer = YearScorer()

    @Test("Empty scored list returns empty result")
    func emptyScored() {
        let result = scorer.resolveScores([])
        #expect(result.year == nil)
        #expect(result.confidence == 0)
    }

    @Test("Single candidate returns its year")
    func singleCandidate() {
        let scored = [makeScoredRelease(year: 2000, score: 80)]
        let result = scorer.resolveScores(scored)
        #expect(result.year == 2000)
        #expect(result.confidence == 80)
    }

    @Test("Highest scoring year wins")
    func highestScoreWins() {
        let scored = [
            makeScoredRelease(year: 2000, score: 60),
            makeScoredRelease(year: 2005, score: 90),
            makeScoredRelease(year: 2010, score: 70),
        ]
        let result = scorer.resolveScores(scored)
        #expect(result.year == 2005)
    }

    @Test("Dedup keeps MAX score per year")
    func dedupMaxScore() {
        let scored = [
            makeScoredRelease(year: 2000, score: 60),
            makeScoredRelease(year: 2000, score: 80),
            makeScoredRelease(year: 2000, score: 70),
        ]
        let result = scorer.resolveScores(scored)
        #expect(result.year == 2000)
        #expect(result.confidence == 80)
    }

    @Test("Existing year boost — existing preferred when close in score")
    func existingYearBoost() {
        let scored = [
            makeScoredRelease(year: 2000, score: 80),
            makeScoredRelease(year: 2005, score: 85),
        ]
        // 2005 is best (85), but 2000 at 80 is >= 85*0.9=76.5 → prefer existing
        let result = scorer.resolveScores(scored, existingYear: 2000)
        #expect(result.year == 2000)
    }

    @Test("Existing year NOT boosted when much lower score")
    func existingYearNotBoosted() {
        let scored = [
            makeScoredRelease(year: 2000, score: 50),
            makeScoredRelease(year: 2005, score: 90),
        ]
        // 2005 is best (90), 2000 at 50 < 90*0.9=81 → don't boost
        let result = scorer.resolveScores(scored, existingYear: 2000)
        #expect(result.year == 2005)
    }

    @Test("Original release preferred over reissue when close")
    func originalReleasePreferred() {
        let scored = [
            makeScoredRelease(year: 2020, score: 85, isReissue: true),
            makeScoredRelease(year: 1997, score: 80, isReissue: false),
        ]
        // Reissue at 85 is best, but original at 80 >= 85*0.9=76.5 → prefer original
        let result = scorer.resolveScores(scored)
        #expect(result.year == 1997)
    }

    @Test("Definitive when high score and large gap")
    func definitiveResult() {
        let scored = [
            makeScoredRelease(year: 2000, score: 90),
            makeScoredRelease(year: 2005, score: 50),
        ]
        let result = scorer.resolveScores(scored)
        // 90 >= threshold(80), gap = 40 >= diff(20), year <= current
        #expect(result.isDefinitive == true)
    }

    @Test("Not definitive when score too low")
    func notDefinitiveLowScore() {
        let scored = [
            makeScoredRelease(year: 2000, score: 60),
        ]
        let result = scorer.resolveScores(scored)
        // 60 < threshold(80)
        #expect(result.isDefinitive == false)
    }

    @Test("Not definitive when gap too small")
    func notDefinitiveSmallGap() {
        let scored = [
            makeScoredRelease(year: 2000, score: 85),
            makeScoredRelease(year: 2001, score: 80),
        ]
        let result = scorer.resolveScores(scored)
        // Gap = 5 < definitiveScoreDiff(20)
        #expect(result.isDefinitive == false)
    }

    @Test("Year scores map included in result")
    func yearScoresMap() {
        let scored = [
            makeScoredRelease(year: 2000, score: 80),
            makeScoredRelease(year: 2005, score: 60),
        ]
        let result = scorer.resolveScores(scored)
        #expect(result.yearScores[2000] == 80)
        #expect(result.yearScores[2005] == 60)
    }

    @Test("Custom scoring config changes weights")
    func customScoringConfig() {
        var config = ScoringConfig()
        config.baseScore = 100
        config.artistExactMatchBonus = 50
        let scorer = YearScorer(config: config)

        let candidate = makeCandidate(artist: "Test", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Test", queryAlbum: "Test")
        #expect(result.breakdown.base == 100)
        #expect(result.breakdown.artistMatch == 50)
    }
}

// MARK: - Test Helpers

private func makeCandidate(
    artist: String,
    album: String,
    year: Int,
    source: APISource = .musicBrainz,
    releaseType: ReleaseType = .album,
    status: ReleaseStatus = .official,
    country: String? = nil,
    isReissue: Bool = false,
    mbReleaseGroupID: String? = nil,
    mbReleaseGroupFirstYear: Int? = nil
) -> ReleaseCandidate {
    ReleaseCandidate(
        artist: artist,
        album: album,
        year: year,
        source: source,
        releaseType: releaseType,
        status: status,
        country: country,
        isReissue: isReissue,
        mbReleaseGroupID: mbReleaseGroupID,
        mbReleaseGroupFirstYear: mbReleaseGroupFirstYear
    )
}

private func makeScoredRelease(
    year: Int,
    score: Int,
    isReissue: Bool = false
) -> ScoredRelease {
    let candidate = ReleaseCandidate(
        artist: "Test",
        album: "Test",
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
