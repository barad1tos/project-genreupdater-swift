import Foundation
import Testing
@testable import Core

// MARK: - YearScorer Tests

@Suite("YearScorer — Multi-Factor Release Scoring")
struct YearScorerScoringTests {
    let scorer = YearScorer()

    private func scoreArtistPeriod(
        forYear year: Int,
        period: (start: Int?, end: Int?) = (start: 2000, end: 2020)
    ) -> Int {
        let candidate = makeCandidate(artist: "X", album: "X", year: year)
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistActivityPeriod: period
        )
        return result.breakdown.artistPeriod
    }

    // MARK: - Base Score

    @Test("Base score is always applied")
    func baseScore() {
        let candidate = makeCandidate(artist: "Test", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Test", queryAlbum: "Test")
        #expect(result.breakdown.base == scorer.config.baseScore)
    }

    // MARK: - Artist Match

    @Test("Exact artist match gives bonus")
    func artistExactMatch() {
        let candidate = makeCandidate(artist: "Radiohead", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Radiohead", queryAlbum: "Test")
        #expect(result.breakdown.artistMatch == scorer.config.artistExactMatchBonus)
    }

    @Test("Fuzzy artist match gives bonus")
    func artistFuzzyMatch() {
        let candidate = makeCandidate(artist: "The Beatles", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Beatles", queryAlbum: "Test")
        // After normalization: "beatles" == "beatles" → exact match bonus
        #expect(result.breakdown.artistMatch == scorer.config.artistExactMatchBonus)
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
        // Python parity: albumExactMatchBonus + perfectMatchBonus when artist also matches.
        #expect(result.breakdown.albumMatch == scorer.config.albumExactMatchBonus + scorer.config.perfectMatchBonus)
    }

    @Test("Album variant treated as substring match for scoring")
    func albumVariant() {
        let candidate = makeCandidate(artist: "X", album: "OK Computer (Remastered)", year: 2017)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "OK Computer")
        // Python parity: normalized strings differ ("okcomputer" vs "okcomputerremastered"),
        // "okcomputer" is substring of "okcomputerremastered" → albumSubstringPenalty
        #expect(result.breakdown.albumMatch == scorer.config.albumSubstringPenalty)
    }

    @Test("Configured edition keywords normalize album match for scoring")
    func albumEditionKeywordsNormalizeScoreMatch() {
        let configuredScorer = YearScorer(editionKeywords: ["deluxe", "edition"])
        let candidate = makeCandidate(artist: "X", album: "Fallen", year: 2003)
        let result = configuredScorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "Fallen (Deluxe Edition)"
        )
        let expectedAlbumMatch = configuredScorer.config.albumExactMatchBonus
            + configuredScorer.config.perfectMatchBonus

        #expect(result.breakdown.albumMatch == expectedAlbumMatch)
    }

    @Test("Unrelated album gives penalty")
    func albumUnrelated() {
        let candidate = makeCandidate(artist: "X", album: "The Bends", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "Kid A")
        #expect(result.breakdown.albumMatch == scorer.config.albumUnrelatedPenalty)
    }

    // MARK: - Release Type

    @Test("Album type gets bonus")
    func releaseTypeAlbum() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .album)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == scorer.config.typeAlbumBonus)
    }

    @Test("EP type gets penalty")
    func releaseTypeEP() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .ep)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == scorer.config.typeEPSinglePenalty)
    }

    @Test("Compilation type gets heavier penalty")
    func releaseTypeCompilation() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .compilation)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == scorer.config.typeCompilationLivePenalty)
    }

    @Test("Remix type gets compilation live penalty")
    func releaseTypeRemix() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .remix)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == scorer.config.typeCompilationLivePenalty)
    }

    @Test("Other type has no release type adjustment")
    func releaseTypeOther() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2000, releaseType: .other)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseType == 0)
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
        #expect(result.breakdown.releaseStatus == scorer.config.statusBootlegPenalty)
    }

    // MARK: - Reissue Penalty

    @Test("Reissue gets penalty")
    func reissuePenalty() {
        let candidate = makeCandidate(artist: "X", album: "X", year: 2020, isReissue: true)
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.reissuePenalty == scorer.config.reissuePenalty)
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
        // diff=20, 1-year grace: penalty = -5 × 19, capped at the configured max.
        #expect(result.breakdown.yearDiff == scorer.config.yearDiffMaxPenalty)
    }

    @Test("Year diff uses MB release group first year as reference")
    func yearDiffUsesRGYear() {
        let candidate = releaseGroupCandidate(
            artist: "X", album: "X", year: 2020,
            releaseGroupFirstYear: 2000
        )
        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            currentYear: 2015
        )
        // Uses mbReleaseGroupFirstYear (2000), diff=20, capped at the configured max.
        #expect(result.breakdown.yearDiff == scorer.config.yearDiffMaxPenalty)
    }

    // MARK: - Artist Period

    @Test("Year before artist start gets penalty")
    func yearBeforeArtistStart() {
        #expect(scoreArtistPeriod(forYear: 1990) == scorer.config.yearBeforeStartPenalty)
    }

    @Test("First year before artist start grace gets penalty")
    func firstYearBeforeArtistStartGraceGetsPenalty() {
        #expect(scoreArtistPeriod(forYear: 1998) == scorer.config.yearBeforeStartPenalty)
    }

    @Test("Year one year before artist start is allowed")
    func yearOneYearBeforeArtistStartAllowed() {
        #expect(scoreArtistPeriod(forYear: 1999) == 0)
    }

    @Test("Year after artist end gets penalty")
    func yearAfterArtistEnd() {
        #expect(scoreArtistPeriod(forYear: 2025) == scorer.config.yearAfterEndPenalty)
    }

    @Test("Year within three years after artist end is allowed")
    func yearWithinGraceAfterArtistEndAllowed() {
        #expect(scoreArtistPeriod(forYear: 2023) == 0)
    }

    @Test("First year after artist end grace gets penalty")
    func firstYearAfterArtistEndGraceGetsPenalty() {
        #expect(scoreArtistPeriod(forYear: 2024) == scorer.config.yearAfterEndPenalty)
    }

    @Test("Year near artist start gets bonus")
    func yearNearArtistStart() {
        #expect(scoreArtistPeriod(forYear: 2001) == scorer.config.yearNearStartBonus)
    }

    @Test("First year after near-start window gets no bonus")
    func firstYearAfterNearStartWindowGetsNoBonus() {
        #expect(scoreArtistPeriod(forYear: 2002) == 0)
    }

    @Test("Year more than one year after artist start gets no near-start bonus")
    func yearOutsideNearArtistStartWindowGetsNoBonus() {
        #expect(scoreArtistPeriod(forYear: 2003) == 0)
    }

    @Test("Extreme artist start year does not overflow scoring")
    func extremeArtistStartYearDoesNotOverflowScoring() {
        #expect(scoreArtistPeriod(forYear: 2000, period: (start: Int.min, end: nil)) == 0)
    }

    @Test("Extreme artist end year does not overflow scoring")
    func extremeArtistEndYearDoesNotOverflowScoring() {
        #expect(scoreArtistPeriod(forYear: 2000, period: (start: nil, end: Int.max)) == 0)
    }

    // MARK: - Source Reliability

    @Test("MusicBrainz source gives highest bonus")
    func sourceMB() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 2000, source: .musicBrainz
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.sourceReliability == scorer.config.sourceMBBonus)
    }

    @Test("Discogs source gives moderate bonus")
    func sourceDiscogs() {
        let candidate = makeCandidate(
            artist: "X", album: "X", year: 2000, source: .discogs
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.sourceReliability == scorer.config.sourceDiscogsBonus)
    }

    // MARK: - Release Group Match

    @Test("MB release group with matching first year gives full bonus")
    func releaseGroupMatchFull() {
        let candidate = releaseGroupCandidate(
            artist: "X", album: "X", year: 1997,
            releaseGroupID: "abc-123",
            releaseGroupFirstYear: 1997
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        #expect(result.breakdown.releaseGroupMatch == scorer.config.mbReleaseGroupMatchBonus)
    }

    @Test("MB release group with different first year gives no bonus")
    func releaseGroupMatchDiff() {
        let candidate = releaseGroupCandidate(
            artist: "X", album: "X", year: 2017,
            releaseGroupID: "abc-123",
            releaseGroupFirstYear: 1997
        )
        let result = scorer.scoreRelease(candidate, queryArtist: "X", queryAlbum: "X")
        // Python parity: RG bonus only when year matches RG first year exactly
        #expect(result.breakdown.releaseGroupMatch == 0)
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
        // Strong exact matches should remain comfortably above the definitive threshold.
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

    @Test("Existing single year remains definitive when API support is stable")
    func existingSingleYearRemainsDefinitiveWhenAPISupportIsStable() {
        var yearLogic = YearLogicConfig()
        yearLogic.definitiveScoreThreshold = 90
        let scorer = YearScorer(yearLogic: yearLogic)
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let existingYear = calendarYear - 4
        let scored = [
            makeScoredRelease(year: existingYear, score: 80),
        ]

        let result = scorer.resolveScores(scored, existingYear: existingYear)

        #expect(result.year == existingYear)
        #expect(result.isDefinitive == true)
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

    @Test("Existing future year is not boosted over stronger non-future candidate")
    func existingFutureYearNotBoosted() {
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let scored = [
            makeScoredRelease(year: calendarYear - 1, score: 100),
            makeScoredRelease(year: calendarYear + 1, score: 91),
        ]

        let result = scorer.resolveScores(
            scored,
            existingYear: calendarYear + 1
        )

        #expect(result.year == calendarYear - 1)
    }

    @Test("Future year preference uses definitive score diff")
    func futureYearPreferenceUsesDefinitiveScoreDiff() {
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let scored = [
            makeScoredRelease(year: calendarYear + 1, score: 100),
            makeScoredRelease(year: calendarYear, score: 89),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == calendarYear)
    }

    @Test("Future year preference only compares the next ranked year")
    func futureYearPreferenceOnlyComparesNextRankedYear() {
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let scored = [
            makeScoredRelease(year: calendarYear + 2, score: 100),
            makeScoredRelease(year: calendarYear + 1, score: 94),
            makeScoredRelease(year: calendarYear, score: 93),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == calendarYear + 2)
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

    @Test("Official original release beats newer promotional candidate")
    func officialOriginalReleaseBeatsNewerPromotionalCandidate() {
        let officialOriginal = releaseGroupCandidate(
            artist: "Test Artist",
            album: "Test Album",
            year: 1998,
            status: .official,
            releaseGroupFirstYear: 1998
        )
        let promotionalReissue = releaseGroupCandidate(
            artist: "Test Artist",
            album: "Test Album",
            year: 1999,
            status: .promotional,
            isReissue: true,
            releaseGroupFirstYear: 1998
        )

        let officialScore = scorer.scoreRelease(
            officialOriginal,
            queryArtist: "Test Artist",
            queryAlbum: "Test Album"
        )
        let promotionalScore = scorer.scoreRelease(
            promotionalReissue,
            queryArtist: "Test Artist",
            queryAlbum: "Test Album"
        )

        #expect(officialScore.totalScore > promotionalScore.totalScore)
        #expect(scorer.resolveScores([promotionalScore, officialScore]).year == 1998)
    }

    @Test("Original release preference requires a multi-year reissue gap")
    func originalReleasePreferenceRequiresMultiYearReissueGap() {
        let scorer = YearScorer(editionKeywords: ["remaster"])
        let scored = [
            makeScoredRelease(year: 2021, score: 85, isReissue: true, album: "Album Remastered"),
            makeScoredRelease(year: 2020, score: 80, isReissue: false, album: "Album"),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == 2021)
    }

    @Test("Original release preference handles extreme candidate years without overflow")
    func originalReleasePreferenceHandlesExtremeCandidateYearsWithoutOverflow() {
        let scored = [
            makeScoredRelease(year: 2021, score: 85),
            makeScoredRelease(year: Int.min, score: 80),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == 2021)
    }

    @Test("Original release preference skips when best title lacks edition keywords")
    func originalReleasePreferenceRequiresEditionKeywordWhenConfigured() {
        let scorer = YearScorer(editionKeywords: ["remaster", "deluxe"])
        let scored = [
            makeScoredRelease(year: 2020, score: 85, album: "Different Album"),
            makeScoredRelease(year: 1997, score: 80, album: "Original Album"),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == 2020)
    }

    @Test("Definitive when high score and large gap")
    func definitiveResult() {
        let scored = [
            makeScoredRelease(year: 2000, score: 90),
            makeScoredRelease(year: 2005, score: 50),
        ]
        let result = scorer.resolveScores(scored)
        // 90 >= threshold(50), gap = 40 >= diff(15), year <= current
        #expect(result.isDefinitive == true)
    }

    @Test("Not definitive when score too low")
    func notDefinitiveLowScore() {
        let scored = [
            makeScoredRelease(year: 2000, score: 40),
        ]
        let result = scorer.resolveScores(scored)
        // 40 < default threshold(50)
        #expect(result.isDefinitive == false)
    }

    @Test("Single old medium-score result is not definitive")
    func singleOldMediumScoreResultIsNotDefinitive() {
        var yearLogic = YearLogicConfig()
        yearLogic.definitiveScoreThreshold = 70
        let scorer = YearScorer(yearLogic: yearLogic)
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let scored = [
            makeScoredRelease(year: calendarYear - 4, score: 80),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == calendarYear - 4)
        #expect(result.isDefinitive == false)
    }

    @Test("Single recent medium-score result remains definitive")
    func singleRecentMediumScoreResultRemainsDefinitive() {
        var yearLogic = YearLogicConfig()
        yearLogic.definitiveScoreThreshold = 70
        let scorer = YearScorer(yearLogic: yearLogic)
        let calendarYear = Calendar.current.component(
            Calendar.Component.year,
            from: Date()
        )
        let scored = [
            makeScoredRelease(year: calendarYear - 1, score: 80),
        ]

        let result = scorer.resolveScores(scored)

        #expect(result.year == calendarYear - 1)
        #expect(result.isDefinitive == true)
    }

    @Test("Definitive when very high score overrides score conflict")
    func definitiveWhenVeryHighScoreOverridesScoreConflict() {
        let scored = [
            makeScoredRelease(year: 2000, score: 85),
            makeScoredRelease(year: 2001, score: 80),
        ]
        let result = scorer.resolveScores(scored)
        // Python parity: very high scores remain definitive despite close scores.
        #expect(result.isDefinitive == true)
    }

    @Test("Not definitive when configured score gap is too small")
    func notDefinitiveWhenConfiguredScoreGapIsTooSmall() {
        var yearLogic = YearLogicConfig()
        yearLogic.definitiveScoreThreshold = 50
        yearLogic.definitiveScoreDiff = 20
        let scorer = YearScorer(yearLogic: yearLogic)
        let scored = [
            makeScoredRelease(year: 2000, score: 70),
            makeScoredRelease(year: 2001, score: 55),
        ]
        let result = scorer.resolveScores(scored)
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
    isReissue: Bool = false
) -> ReleaseCandidate {
    ReleaseCandidate(
        artist: artist,
        album: album,
        year: year,
        source: source,
        releaseType: releaseType,
        status: status,
        isReissue: isReissue
    )
}

private func releaseGroupCandidate(
    artist: String,
    album: String,
    year: Int,
    status: ReleaseStatus = .official,
    isReissue: Bool = false,
    releaseGroupID: String? = nil,
    releaseGroupFirstYear: Int
) -> ReleaseCandidate {
    ReleaseCandidate(
        artist: artist,
        album: album,
        year: year,
        source: .musicBrainz,
        status: status,
        isReissue: isReissue,
        mbReleaseGroupID: releaseGroupID,
        mbReleaseGroupFirstYear: releaseGroupFirstYear
    )
}

private func makeScoredRelease(
    year: Int,
    score: Int,
    isReissue: Bool = false,
    album: String = "Test"
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
