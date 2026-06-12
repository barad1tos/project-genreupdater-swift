// swiftlint:disable file_length
// YearScorer.swift — Multi-factor release scoring and year resolution
// Ported from: year_scoring.py (947 LOC) + year_score_resolver.py (525 LOC)
//
// Pure struct (TDD Decision 9). Scores release candidates using 14 factors,
// then resolves scores to determine the best year.

import Foundation

private let veryHighScoreThreshold = 75

// MARK: - YearScorer

/// Scores release candidates and resolves the best year from scored results.
///
/// Scoring uses 14 weighted factors (configurable via ScoringConfig):
/// base, artist match, album match, soundtrack compensation, release group,
/// release type, release status, reissue penalty, year diff, artist period,
/// country, source reliability, future year, current year.
///
/// Resolution deduplicates by year (MAX score per year), applies existing year
/// boost, future year preference, and determines definitiveness.
public struct YearScorer: Sendable {
    public let config: ScoringConfig
    public let yearLogic: YearLogicConfig

    public init(
        config: ScoringConfig = ScoringConfig(),
        yearLogic: YearLogicConfig = YearLogicConfig()
    ) {
        self.config = config
        self.yearLogic = yearLogic
    }

    // MARK: - Score One Release

    /// Score a single release candidate against query metadata.
    ///
    /// - Parameters:
    ///   - candidate: The release to score
    ///   - queryArtist: The artist name from the user's library
    ///   - queryAlbum: The album name from the user's library
    ///   - currentYear: The existing year in the user's library (if any)
    ///   - artistActivityPeriod: Known activity years (start, end) for the artist
    ///   - artistCountry: The artist's country code (if known)
    /// - Returns: Scored release with breakdown
    public func scoreRelease(
        _ candidate: ReleaseCandidate,
        queryArtist: String,
        queryAlbum: String,
        currentYear: Int? = nil,
        artistActivityPeriod: (start: Int?, end: Int?)? = nil,
        artistCountry: String? = nil
    ) -> ScoredRelease {
        // Python parity: reject invalid years early (year=0 or < minValidYear)
        if candidate.year < yearLogic.minValidYear {
            return ScoredRelease(
                candidate: candidate,
                totalScore: 0,
                breakdown: ScoreBreakdown()
            )
        }

        var breakdown = ScoreBreakdown()

        // 1. Base score
        breakdown.base = config.baseScore

        // 2. Artist match
        breakdown.artistMatch = scoreArtistMatch(
            query: queryArtist,
            candidate: candidate.artist
        )

        // 3. Album match (Python parity: perfect match bonus depends on artist match)
        breakdown.albumMatch = scoreAlbumMatch(
            query: queryAlbum,
            candidate: candidate.album,
            artistMatchScore: breakdown.artistMatch
        )

        // 4. Soundtrack compensation
        breakdown.soundtrackCompensation = scoreSoundtrackCompensation(
            queryAlbum: queryAlbum,
            candidateAlbum: candidate.album,
            releaseType: candidate.releaseType,
            artistMatchScore: breakdown.artistMatch
        )

        // 5. MB release group match
        breakdown.releaseGroupMatch = scoreReleaseGroupMatch(candidate)

        // 6. Release type
        breakdown.releaseType = scoreReleaseType(candidate.releaseType)

        // 7. Release status
        breakdown.releaseStatus = scoreReleaseStatus(candidate.status)

        // 8. Reissue penalty
        breakdown.reissuePenalty = candidate.isReissue ? config.reissuePenalty : 0

        // 9. Year difference from existing
        breakdown.yearDiff = scoreYearDiff(
            candidateYear: candidate.year,
            referenceYear: candidate.mbReleaseGroupFirstYear ?? currentYear
        )

        // 10. Artist activity period
        breakdown.artistPeriod = scoreArtistPeriod(
            candidateYear: candidate.year,
            period: artistActivityPeriod
        )

        // 11. Country/region
        breakdown.country = scoreCountry(
            candidateCountry: candidate.country,
            artistCountry: artistCountry
        )

        // 12. Source reliability
        breakdown.sourceReliability = scoreSourceReliability(candidate.source)

        // 13. Future year penalty
        let calendarYear = Calendar.current.component(
            Calendar.Component.year, from: Date()
        )
        breakdown.futureYearPenalty = candidate.year > calendarYear
            ? config.futureYearPenalty : 0

        // 14. Current year penalty
        breakdown.currentYearPenalty = candidate.year == calendarYear
            ? config.currentYearPenalty : 0

        return ScoredRelease(
            candidate: candidate,
            totalScore: breakdown.totalScore,
            breakdown: breakdown
        )
    }

    // MARK: - Score Resolution

    /// Resolve scored releases into a final year result.
    ///
    /// Algorithm:
    /// 1. Dedup: keep MAX score per year
    /// 2. Sort: score DESC, then year ASC (for ties)
    /// 3. Existing year boost: if existing year's score >= 90% of best → prefer
    /// 4. Future year preference: prefer non-future if close in score
    /// 5. Definitiveness: high score AND gap to runner-up
    ///
    /// - Parameters:
    ///   - scored: All scored release candidates
    ///   - existingYear: The year currently in the user's library
    /// - Returns: Final year determination result
    public func resolveScores(
        _ scored: [ScoredRelease],
        existingYear: Int? = nil
    ) -> YearResult {
        guard !scored.isEmpty else {
            return YearResult()
        }

        // Step 1: Dedup — MAX score per year
        var bestPerYear: [Int: Int] = [:]
        for release in scored {
            let year = release.candidate.year
            bestPerYear[year] = max(bestPerYear[year] ?? Int.min, release.totalScore)
        }

        // Step 2: Sort by score DESC, then year ASC
        let sortedYears = bestPerYear.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        guard let (bestYear, bestScore) = sortedYears.first else {
            return YearResult()
        }

        let calendarYear = Calendar.current.component(
            Calendar.Component.year, from: Date()
        )

        // Steps 3-5: Apply adjustments
        var (finalYear, finalScore) = applyExistingYearBoost(
            year: bestYear, score: bestScore,
            bestPerYear: bestPerYear,
            existingYear: existingYear,
            bestScore: bestScore
        )

        let existingYearBoosted = (finalYear != bestYear)

        (finalYear, finalScore) = applyFutureYearPreference(
            year: finalYear, score: finalScore,
            bestPerYear: bestPerYear,
            sortedYears: sortedYears,
            calendarYear: calendarYear
        )

        (finalYear, finalScore) = applyOriginalReleasePreference(
            year: finalYear, score: finalScore,
            scored: scored,
            existingYearBoosted: existingYearBoosted
        )

        let hasScoreConflict = checkScoreConflict(
            finalYear: finalYear,
            finalScore: finalScore,
            sortedYears: sortedYears,
            calendarYear: calendarYear
        )

        // Step 6: Determine definitiveness
        let isDefinitive = checkDefinitiveness(
            finalScore: finalScore,
            finalYear: finalYear,
            calendarYear: calendarYear,
            hasScoreConflict: hasScoreConflict
        )

        let confidence = min(100, max(0, finalScore))

        return YearResult(
            year: finalScore > 0 ? finalYear : nil,
            isDefinitive: isDefinitive,
            confidence: confidence,
            rawScore: finalScore,
            yearScores: bestPerYear
        )
    }

    // MARK: - Resolution Helpers

    private func applyExistingYearBoost(
        year: Int, score: Int,
        bestPerYear: [Int: Int],
        existingYear: Int?,
        bestScore: Int
    ) -> (year: Int, score: Int) {
        guard let existing = existingYear,
              let existingScore = bestPerYear[existing],
              existing != year else {
            return (year, score)
        }
        let threshold = Double(bestScore) * 0.9
        if Double(existingScore) >= threshold {
            return (existing, existingScore)
        }
        return (year, score)
    }

    private func applyFutureYearPreference(
        year: Int, score: Int,
        bestPerYear: [Int: Int],
        sortedYears: [(key: Int, value: Int)],
        calendarYear: Int
    ) -> (year: Int, score: Int) {
        guard year > calendarYear else {
            return (year, score)
        }
        guard let nonFuture = sortedYears.first(
            where: { $0.key <= calendarYear }
        ) else {
            return (year, score)
        }
        let futureScore = bestPerYear[year] ?? 0
        if Double(nonFuture.value)
            >= Double(futureScore) * 0.9 {
            return (nonFuture.key, nonFuture.value)
        }
        return (year, score)
    }

    /// Python parity: prefer the earliest year (likely original release) when its
    /// score is within 90% of the best. Skip if existing year was already boosted
    /// to avoid undoing that preference.
    private func applyOriginalReleasePreference(
        year: Int, score: Int,
        scored: [ScoredRelease],
        existingYearBoosted: Bool
    ) -> (year: Int, score: Int) {
        guard !existingYearBoosted else {
            return (year, score)
        }

        guard let earliestYear = scored.map(\.candidate.year).min(),
              earliestYear < year else {
            return (year, score)
        }

        guard let earliestScore = scored
            .filter({ $0.candidate.year == earliestYear })
            .max(by: { $0.totalScore < $1.totalScore })?
            .totalScore else {
            return (year, score)
        }

        if Double(earliestScore) >= Double(score) * 0.9 {
            return (earliestYear, earliestScore)
        }
        return (year, score)
    }

    private func checkScoreConflict(
        finalYear: Int,
        finalScore: Int,
        sortedYears: [(key: Int, value: Int)],
        calendarYear: Int
    ) -> Bool {
        guard sortedYears.count > 1 else {
            return false
        }
        guard let competingYear = sortedYears.first(where: { $0.key != finalYear }) else {
            return false
        }
        guard finalScore - competingYear.value < yearLogic.definitiveScoreDiff else {
            return false
        }

        let finalYearIsFuture = finalYear > calendarYear
        let competingYearIsFuture = competingYear.key > calendarYear
        if !finalYearIsFuture, competingYearIsFuture {
            return false
        }

        return true
    }

    /// Python parity: definitiveness requires the configured score threshold,
    /// a non-future year, and either a very high score or no close-score conflict.
    private func checkDefinitiveness(
        finalScore: Int,
        finalYear: Int,
        calendarYear: Int,
        hasScoreConflict: Bool
    ) -> Bool {
        finalScore >= yearLogic.definitiveScoreThreshold
            && finalYear <= calendarYear
            && (finalScore >= veryHighScoreThreshold || !hasScoreConflict)
    }
}

// MARK: - Individual Scoring Factors

extension YearScorer {
    private func scoreArtistMatch(query: String, candidate: String) -> Int {
        let normQuery = normalizeArtistForMatching(query)
        let normCandidate = normalizeArtistForMatching(candidate)

        // Exact match after normalization
        if normQuery == normCandidate {
            return config.artistExactMatchBonus
        }

        // Cross-script detection (Python parity: one Latin + one non-Latin)
        let queryScript = dominantScript(of: query)
        let candidateScript = dominantScript(of: candidate)
        if queryScript != candidateScript,
           queryScript != .unknown, candidateScript != .unknown,
           isCrossScriptComparison(queryScript, candidateScript) {
            return config.artistCrossScriptPenalty
        }

        // Substring match
        if normQuery.contains(normCandidate) || normCandidate.contains(normQuery) {
            return config.artistSubstringPenalty
        }

        // Fuzzy match
        if fuzzyArtistMatch(query, candidate) {
            return config.artistExactMatchBonus
        }

        return config.artistMismatchPenalty
    }

    private func scoreAlbumMatch(
        query: String,
        candidate: String,
        artistMatchScore: Int = 0
    ) -> Int {
        // Python parity: normalize by lowercasing + removing non-alphanumeric
        // (no edition stripping — Python only strips if remaster_keywords provided)
        let compQuery = normalizeForScoreComparison(query)
        let compCandidate = normalizeForScoreComparison(candidate)

        // Exact match (Python: comp_release_title == comp_album_norm)
        if compQuery == compCandidate {
            var bonus = config.albumExactMatchBonus
            // Python parity: add perfectMatchBonus when artist also matched
            if artistMatchScore > 0 {
                bonus += config.perfectMatchBonus
            }
            return bonus
        }

        // Substring match
        if compQuery.contains(compCandidate) || compCandidate.contains(compQuery) {
            return config.albumSubstringPenalty
        }

        return config.albumUnrelatedPenalty
    }

    /// Python parity: normalize by lowercasing and removing non-alphanumeric characters.
    /// Matches Python's `_normalize_for_comparison`.
    private func normalizeForScoreComparison(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }.joined()
    }

    private func scoreSoundtrackCompensation(
        queryAlbum: String,
        candidateAlbum: String,
        releaseType: ReleaseType,
        artistMatchScore: Int
    ) -> Int {
        // Compensate for soundtrack albums where artist mismatch is expected
        guard releaseType == .soundtrack || isSoundtrackAlbum(queryAlbum) else {
            return 0
        }
        // Only compensate if artist was penalized
        guard artistMatchScore < 0 else { return 0 }
        // Album names should still match
        let albumSimilar = fuzzyAlbumMatch(queryAlbum, candidateAlbum, threshold: 0.7)
        return albumSimilar ? config.soundtrackCompensationBonus : 0
    }

    private func scoreReleaseGroupMatch(_ candidate: ReleaseCandidate) -> Int {
        // Python parity: RG bonus based on first year presence + source + year match
        guard let firstYear = candidate.mbReleaseGroupFirstYear else { return 0 }
        // Full bonus only for MusicBrainz source where year matches RG first year
        if candidate.source == .musicBrainz, firstYear == candidate.year {
            return config.mbReleaseGroupMatchBonus
        }
        return 0
    }

    private func scoreReleaseType(_ type: ReleaseType) -> Int {
        switch type {
        case .album:
            config.typeAlbumBonus
        case .ep, .single:
            config.typeEPSinglePenalty
        case .compilation, .live, .soundtrack:
            config.typeCompilationLivePenalty
        case .remix, .other:
            config.typeEPSinglePenalty
        }
    }

    private func scoreReleaseStatus(_ status: ReleaseStatus) -> Int {
        switch status {
        case .official:
            config.statusOfficialBonus
        case .bootleg:
            config.statusBootlegPenalty
        case .promotional:
            config.statusPromoPenalty
        case .pseudoRelease, .other:
            0
        }
    }

    private func scoreYearDiff(candidateYear: Int, referenceYear: Int?) -> Int {
        guard let ref = referenceYear else { return 0 }
        let diff = abs(candidateYear - ref)
        // Python parity: only penalize when diff > 1 (1-year grace),
        // and use (diff - 1) to match year_scoring.py:735
        guard diff > 1 else { return 0 }
        let penalty = config.yearDiffPenaltyScale * (diff - 1)
        // max() caps severity: max(-95, -50) = -50 (less severe)
        return max(penalty, config.yearDiffMaxPenalty)
    }

    private func scoreArtistPeriod(
        candidateYear: Int,
        period: (start: Int?, end: Int?)?
    ) -> Int {
        guard let period else { return 0 }

        if let start = period.start {
            if candidateYear < start {
                return config.yearBeforeStartPenalty
            }
            // Near start bonus: within 3 years of start
            if candidateYear >= start, candidateYear <= start + 3 {
                return config.yearNearStartBonus
            }
        }

        if let end = period.end, candidateYear > end {
            return config.yearAfterEndPenalty
        }

        return 0
    }

    /// Python parity: country scoring only applies when artistCountry is known.
    /// When artistCountry is nil, return 0 (no major market bonus either).
    private func scoreCountry(
        candidateCountry: String?,
        artistCountry: String?
    ) -> Int {
        guard let country = candidateCountry, let artistCountry else { return 0 }

        let normalizedCountry = normalizeCountryCode(country)
        if normalizedCountry == normalizeCountryCode(artistCountry) {
            return config.countryArtistMatchBonus
        }

        let normalizedMajorMarkets = Set(yearLogic.majorMarketCodes.map(normalizeCountryCode))
        if normalizedMajorMarkets.contains(normalizedCountry) {
            return config.countryMajorMarketBonus
        }

        return 0
    }

    private func normalizeCountryCode(_ code: String) -> String {
        let normalizedCode = code.uppercased()
        if normalizedCode == "UK" {
            return "GB"
        }
        return normalizedCode
    }

    private func scoreSourceReliability(_ source: APISource) -> Int {
        switch source {
        case .musicBrainz:
            config.sourceMBBonus
        case .discogs:
            config.sourceDiscogsBonus
        case .itunes:
            config.sourceITunesBonus
        case .unknown:
            0
        }
    }

    private func isSoundtrackAlbum(_ album: String) -> Bool {
        let lower = album.lowercased()
        let keywords = [
            "soundtrack",
            "ost",
            "original score",
            "motion picture",
            "film score"
        ]
        return keywords.contains { lower.contains($0) }
    }

    /// Python parity: cross-script = one is Latin AND other is non-Latin.
    private func isCrossScriptComparison(
        _ script1: ScriptType,
        _ script2: ScriptType
    ) -> Bool {
        let nonLatinScripts: Set<ScriptType> = [
            .cyrillic, .chinese, .japanese, .korean,
            .arabic, .hebrew, .greek, .thai, .devanagari
        ]
        let s1Latin = script1 == .latin
        let s2Latin = script2 == .latin
        let s1NonLatin = nonLatinScripts.contains(script1)
        let s2NonLatin = nonLatinScripts.contains(script2)
        return (s1Latin && s2NonLatin) || (s1NonLatin && s2Latin)
    }
}
