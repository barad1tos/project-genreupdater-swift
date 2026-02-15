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

    /// Minimum score to cache a result.
    public static let minConfidenceToCache = 50

    public init(
        scorer: YearScorer = YearScorer(),
        validator: YearValidator = YearValidator(),
        fallback: YearFallbackStrategy = YearFallbackStrategy()
    ) {
        self.scorer = scorer
        self.validator = validator
        self.fallback = fallback
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

        // Step 1: Check for cross-track consensus
        if let consensus = validator.getConsensusReleaseYear(
            tracks: albumTracks
        ) {
            let validation = validator.validate(year: consensus)
            if case .valid = validation {
                return YearDeterminationResult(
                    yearResult: YearResult(
                        year: consensus,
                        isDefinitive: true,
                        confidence: 95
                    ),
                    source: .consensus,
                    candidateCount: candidates.count
                )
            }
        }

        // Step 2: Check dominant year across tracks
        if let dominant = validator.getDominantYear(
            tracks: albumTracks
        ), !dominant.isSuspicious, dominant.confidence >= 0.8 {
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: dominant.year,
                    isDefinitive: dominant.confidence >= 0.9,
                    confidence: Int(dominant.confidence * 100)
                ),
                source: .dominant,
                candidateCount: candidates.count
            )
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

    /// Check if a track should be skipped before processing.
    ///
    /// - Parameters:
    ///   - track: The track to check
    ///   - albumTracks: Other tracks on the album
    /// - Returns: Skip reason, or nil if processing should continue
    public func preFlightCheck(
        track: Track,
        albumTracks: [Track]
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

        return nil
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

    private func mapDecisionToResult(
        decision: FallbackDecision,
        yearResult: YearResult,
        scored: [ScoredRelease],
        candidateCount: Int
    ) -> YearDeterminationResult {
        let bestBreakdown = scored
            .max(by: { $0.totalScore < $1.totalScore })?
            .breakdown

        switch decision {
        case let .useAPIYear(year, confidence):
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: year,
                    isDefinitive: yearResult.isDefinitive,
                    confidence: confidence,
                    yearScores: yearResult.yearScores
                ),
                source: .api,
                breakdown: bestBreakdown,
                fallbackDecision: decision,
                candidateCount: candidateCount
            )

        case .keepExisting:
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: yearResult.year,
                    isDefinitive: false,
                    confidence: yearResult.confidence,
                    yearScores: yearResult.yearScores
                ),
                source: .library,
                breakdown: bestBreakdown,
                fallbackDecision: decision,
                candidateCount: candidateCount
            )

        case .escalateToVerification:
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: yearResult.year,
                    isDefinitive: false,
                    confidence: yearResult.confidence,
                    yearScores: yearResult.yearScores
                ),
                source: .fallback,
                breakdown: bestBreakdown,
                fallbackDecision: decision,
                candidateCount: candidateCount
            )

        case .markAndSkip:
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: nil,
                    isDefinitive: false,
                    confidence: 0,
                    yearScores: yearResult.yearScores
                ),
                source: .fallback,
                breakdown: bestBreakdown,
                fallbackDecision: decision,
                candidateCount: candidateCount
            )

        case .noAction:
            return YearDeterminationResult(
                yearResult: yearResult,
                source: .fallback,
                breakdown: bestBreakdown,
                fallbackDecision: decision,
                candidateCount: candidateCount
            )
        }
    }
}
