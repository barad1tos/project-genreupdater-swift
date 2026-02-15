// YearDeterminator.swift — Year determination orchestrator
// Ported from: year_determination.py (800+ LOC)
//
// Orchestrates the full year determination flow:
// cache → API → score → validate → fallback → persist

import Foundation

// MARK: - YearDeterminator

/// Orchestrates year determination by composing scorer, validator,
/// and fallback strategy with external services.
///
/// Flow:
/// 1. Pre-flight checks (already processed, rejected, prerelease)
/// 2. Check cache → return if high confidence
/// 3. Call API → get release candidates
/// 4. Score all candidates
/// 5. Validate (dominant year, consensus)
/// 6. Run fallback strategy
/// 7. Cache result, return determination
public struct YearDeterminator: Sendable {
    public let scorer: YearScorer
    public let validator: YearValidator
    public let fallback: YearFallbackStrategy
    public let processingConfig: ProcessingConfig

    public init(
        scorer: YearScorer = YearScorer(),
        validator: YearValidator = YearValidator(),
        fallback: YearFallbackStrategy = YearFallbackStrategy(),
        processingConfig: ProcessingConfig = ProcessingConfig()
    ) {
        self.scorer = scorer
        self.validator = validator
        self.fallback = fallback
        self.processingConfig = processingConfig
    }

    // MARK: - Determine Year (Pure Logic)

    /// Determine the best year from release candidates.
    ///
    /// This is the pure-logic core: given candidates and context,
    /// it scores, resolves, validates, and applies fallback rules.
    /// No I/O — API calls and caching are the caller's responsibility.
    ///
    /// - Parameters:
    ///   - candidates: Release candidates from external APIs
    ///   - track: The track to determine year for
    ///   - albumTracks: Other tracks on the same album
    ///   - currentYear: Existing year in the library
    ///   - artistActivityPeriod: Known activity range
    ///   - artistCountry: Artist's country code
    ///   - albumTypeInfo: Album classification result
    ///   - verificationAttempts: Previous escalation count
    /// - Returns: Year determination result with source and breakdown
    public func determineYear(
        candidates: [ReleaseCandidate],
        track: Track,
        albumTracks: [Track] = [],
        currentYear: Int? = nil,
        artistActivityPeriod: (start: Int?, end: Int?)? = nil,
        artistCountry: String? = nil,
        albumTypeInfo: AlbumTypeInfo? = nil,
        verificationAttempts: Int = 0
    ) -> YearDeterminationResult {
        let effectiveCurrentYear = currentYear ?? track.year

        // Steps 1-2: Cross-track year (dominant, consensus)
        if let result = checkCrossTrackYear(
            albumTracks: albumTracks,
            candidateCount: candidates.count
        ) {
            return result
        }

        // Step 3: Score candidates
        guard !candidates.isEmpty else {
            return noResultDetermination(
                currentYear: effectiveCurrentYear
            )
        }

        let scored = candidates.map { candidate in
            scorer.scoreRelease(
                candidate,
                queryArtist: track.effectiveArtist,
                queryAlbum: track.album,
                currentYear: effectiveCurrentYear,
                artistActivityPeriod: artistActivityPeriod,
                artistCountry: artistCountry
            )
        }

        // Step 4: Resolve scores to best year
        let yearResult = scorer.resolveScores(
            scored,
            existingYear: effectiveCurrentYear
        )

        // Step 5: Apply fallback strategy
        let fallbackContext = FallbackContext(
            scoredReleases: scored,
            existingYear: effectiveCurrentYear,
            track: track,
            albumTracks: albumTracks,
            isDefinitive: yearResult.isDefinitive,
            bestScore: yearResult.confidence,
            bestYear: yearResult.year,
            albumTypeInfo: albumTypeInfo,
            verificationAttempts: verificationAttempts
        )

        let decision = fallback.decide(fallbackContext)

        // Step 6: Map fallback decision to result
        return mapDecisionToResult(
            decision: decision,
            yearResult: yearResult,
            scored: scored,
            candidateCount: candidates.count
        )
    }

    // MARK: - Pre-flight Checks

    // suspiciousAlbumMinLen and suspiciousManyYears are in ProcessingConfig

    /// Check if a track should be skipped before processing.
    ///
    /// - Parameters:
    ///   - track: The track to check
    ///   - albumTracks: Other tracks on the album
    ///   - futureYearThreshold: Max allowed years beyond current
    ///     (default 1, from ProcessingConfig)
    /// - Returns: Skip reason, or nil if processing should continue
    public func preFlightCheck(
        track: Track,
        albumTracks: [Track],
        futureYearThreshold: Int = 1
    ) -> String? {
        // Skip if already processed by MGU
        if track.hasBeenProcessed {
            return "Already processed by Genre Updater"
        }

        // Skip prerelease tracks
        if track.kind == .prerelease {
            return "Prerelease track"
        }

        // Skip if track can't be edited
        if !track.canEdit {
            return "Track is not editable"
        }

        // Skip suspicious albums (short name + many unique years)
        if let reason = checkSuspiciousAlbum(
            track: track, albumTracks: albumTracks
        ) {
            return reason
        }

        // Skip albums with far-future years
        if let reason = checkFutureYears(
            albumTracks: albumTracks,
            futureYearThreshold: futureYearThreshold
        ) {
            return reason
        }

        return nil
    }

    /// Check if the album is suspicious and should be skipped.
    ///
    /// A short album name (≤ 3 chars) combined with many unique
    /// years (≥ 3) suggests a self-titled or single-letter album
    /// that aggregates unrelated tracks. Ported from
    /// `check_suspicious_album` in year_determination.py.
    public func checkSuspiciousAlbum(
        track: Track,
        albumTracks: [Track]
    ) -> String? {
        let albumName = track.album
        guard albumName.count <= processingConfig.suspiciousAlbumMinLen else {
            return nil
        }

        let uniqueYears = Set(
            albumTracks.compactMap(\.year)
        )
        guard uniqueYears.count >= processingConfig.suspiciousManyYears else {
            return nil
        }

        return "Suspicious album '\(albumName)': "
            + "\(uniqueYears.count) unique years, "
            + "name length=\(albumName.count)"
    }

    /// Check if album tracks contain far-future years.
    ///
    /// If the max year exceeds currentYear + threshold, the album
    /// is likely a prerelease and should be skipped. Years within
    /// the threshold (default 1 year ahead) are tolerated.
    /// Ported from `handle_future_years` in year_determination.py.
    public func checkFutureYears(
        albumTracks: [Track],
        futureYearThreshold: Int = 1
    ) -> String? {
        let currentYear = Calendar.current.component(
            .year, from: Date()
        )
        let futureYears = albumTracks
            .compactMap(\.year)
            .filter { $0 > currentYear }

        guard let maxFutureYear = futureYears.max() else {
            return nil
        }

        // Within threshold — tolerate (e.g. album releasing next year)
        if maxFutureYear - currentYear <= futureYearThreshold {
            return nil
        }

        return "Future year \(maxFutureYear) exceeds threshold "
            + "(\(futureYearThreshold) year(s) beyond \(currentYear))"
    }

    // MARK: - Helpers

    private func noResultDetermination(
        currentYear: Int?
    ) -> YearDeterminationResult {
        if let year = currentYear {
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: year,
                    isDefinitive: false,
                    confidence: 0
                ),
                source: .library,
                candidateCount: 0
            )
        }
        return YearDeterminationResult(
            yearResult: YearResult(),
            source: .fallback,
            candidateCount: 0
        )
    }

    private func checkCrossTrackYear(
        albumTracks: [Track],
        candidateCount: Int
    ) -> YearDeterminationResult? {
        // Step 1: Dominant year (Python parity: dominant first)
        if let dominant = validator.getDominantYear(
            tracks: albumTracks
        ), !dominant.isSuspicious,
        dominant.confidence >= validator.config.dominantYearMinConfidence {
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: dominant.year,
                    isDefinitive: dominant.confidence >= 0.9,
                    confidence: Int(dominant.confidence * 100)
                ),
                source: .dominant,
                candidateCount: candidateCount
            )
        }

        // Step 2: Consensus release year
        if let consensus = validator.getConsensusReleaseYear(
            tracks: albumTracks
        ) {
            let validation = validator.validate(
                year: consensus
            )
            if case .valid = validation {
                return YearDeterminationResult(
                    yearResult: YearResult(
                        year: consensus,
                        isDefinitive: true,
                        confidence: 95
                    ),
                    source: .consensus,
                    candidateCount: candidateCount
                )
            }
        }

        return nil
    }

    private func mapDecisionToResult(
        decision: FallbackDecision,
        yearResult: YearResult,
        scored: [ScoredRelease],
        candidateCount: Int
    ) -> YearDeterminationResult {
        let bestBreakdown = scored
            .max(by: { $0.totalScore < $1.totalScore })?
            .breakdown

        let (mapped, source) = mapFallbackDecision(
            decision, yearResult: yearResult
        )

        return YearDeterminationResult(
            yearResult: mapped,
            source: source,
            breakdown: bestBreakdown,
            fallbackDecision: decision,
            candidateCount: candidateCount
        )
    }

    private func mapFallbackDecision(
        _ decision: FallbackDecision,
        yearResult: YearResult
    ) -> (YearResult, YearSource) {
        switch decision {
        case let .useAPIYear(year, confidence):
            (YearResult(
                year: year,
                isDefinitive: yearResult.isDefinitive,
                confidence: confidence,
                yearScores: yearResult.yearScores
            ), .api)

        case .keepExisting:
            (YearResult(
                year: yearResult.year,
                isDefinitive: false,
                confidence: yearResult.confidence,
                yearScores: yearResult.yearScores
            ), .library)

        case .escalateToVerification:
            (YearResult(
                year: yearResult.year,
                isDefinitive: false,
                confidence: yearResult.confidence,
                yearScores: yearResult.yearScores
            ), .fallback)

        case .markAndSkip:
            (YearResult(
                year: nil,
                isDefinitive: false,
                confidence: 0,
                yearScores: yearResult.yearScores
            ), .fallback)

        case .noAction:
            (yearResult, .fallback)
        }
    }
}
