// YearDeterminator.swift — Year determination orchestrator
// Ported from: year_determination.py (800+ LOC)
//
// Orchestrates the full year determination flow:
// cache → API → score → validate → fallback → persist

import Foundation
import OSLog

// MARK: - YearDeterminator

/// Album-level integrity risk that must stop automatic year lookup.
public enum YearSafetyIssue: Equatable, Sendable {
    case suspiciousAlbum(uniqueYearCount: Int, albumNameLength: Int)
    case farFutureYear(year: Int)
}

/// Orchestrates year determination by composing scorer, validator,
/// and fallback strategy with external services.
///
/// The pure determination order is dominant editable metadata, release-year
/// consensus, candidate scoring, then fallback. Services own cache and API I/O.
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
    ///   - queryAlbum: Album text used to score candidates when cleaning removed search evidence
    /// - Returns: Year determination result with source and breakdown
    public func determineYear(
        candidates: [ReleaseCandidate],
        track: Track,
        albumTracks: [Track] = [],
        currentYear: Int? = nil,
        artistActivityPeriod: (start: Int?, end: Int?)? = nil,
        artistCountry: String? = nil,
        albumTypeInfo: AlbumTypeInfo? = nil,
        verificationAttempts: Int = 0,
        queryAlbum: String? = nil
    ) -> YearDeterminationResult {
        let signpostState = AppSignpost.yearDetermination.beginInterval("determineYear")
        defer { AppSignpost.yearDetermination.endInterval("determineYear", signpostState) }

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
                currentYear: effectiveCurrentYear,
                candidateCount: candidates.count
            )
        }

        let currentCalendarYear = currentUTCYear()
        let validCandidates = candidates.filter { candidate in
            candidate.year >= validator.config.minValidYear
                && candidate.year <= currentCalendarYear
        }
        guard !validCandidates.isEmpty else {
            return noResultDetermination(
                currentYear: effectiveCurrentYear,
                candidateCount: candidates.count
            )
        }

        // Score against the canonical album-grouping artist. Feature credits
        // do not become album identities, while soundtrack compensation handles
        // the intentional artist mismatch in rewritten soundtrack searches.
        let scored = validCandidates.map { candidate in
            scorer.scoreRelease(
                candidate,
                queryArtist: AlbumIdentity.groupingArtist(for: track),
                queryAlbum: queryAlbum ?? track.album,
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

    /// Returns the first configured integrity risk before local, cache, or API year lookup.
    ///
    /// The target track is added to missing album context. Suspicious album evidence
    /// is evaluated first and is always active; prerelease skipping controls only the
    /// subsequent far-future-year check.
    public func yearSafetyIssue(
        track: Track,
        albumTracks: [Track]
    ) -> YearSafetyIssue? {
        let contextTracks = albumTracks.contains { $0.id == track.id }
            ? albumTracks
            : albumTracks + [track]
        if let issue = suspiciousAlbumIssue(track: track, albumTracks: contextTracks) {
            return issue
        }
        guard processingConfig.skipPrerelease else {
            return nil
        }
        return futureYearIssue(
            albumTracks: contextTracks,
            futureYearThreshold: processingConfig.futureYearThreshold
        )
    }

    private func suspiciousAlbumIssue(
        track: Track,
        albumTracks: [Track]
    ) -> YearSafetyIssue? {
        let albumNameLength = track.album.count
        guard albumNameLength <= processingConfig.suspiciousAlbumMinLen else {
            return nil
        }

        let uniqueYearCount = Set(albumTracks.compactMap(\.year)).count
        guard uniqueYearCount >= processingConfig.suspiciousManyYears else {
            return nil
        }

        return .suspiciousAlbum(
            uniqueYearCount: uniqueYearCount,
            albumNameLength: albumNameLength
        )
    }

    private func futureYearIssue(
        albumTracks: [Track],
        futureYearThreshold: Int
    ) -> YearSafetyIssue? {
        let currentYear = currentUTCYear()
        let futureYears = albumTracks.compactMap(\.year).filter { $0 > currentYear }
        guard let maxFutureYear = futureYears.max() else {
            return nil
        }
        guard maxFutureYear - currentYear > futureYearThreshold else {
            return nil
        }

        return .farFutureYear(year: maxFutureYear)
    }

    private func currentUTCYear() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.year, from: Date())
    }

    // MARK: - Helpers

    private func noResultDetermination(
        currentYear: Int?,
        candidateCount: Int
    ) -> YearDeterminationResult {
        if let year = currentYear {
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: year,
                    isDefinitive: false,
                    confidence: 0
                ),
                source: .library,
                candidateCount: candidateCount
            )
        }
        return YearDeterminationResult(
            yearResult: YearResult(),
            source: .fallback,
            candidateCount: candidateCount
        )
    }

    private func checkCrossTrackYear(
        albumTracks: [Track],
        candidateCount: Int
    ) -> YearDeterminationResult? {
        dominantDetermination(
            albumTracks: albumTracks,
            candidateCount: candidateCount
        ) ?? consensusDetermination(
            albumTracks: albumTracks,
            candidateCount: candidateCount
        )
    }

    /// Returns trusted dominant editable-year evidence without falling through to another local source.
    public func dominantDetermination(
        albumTracks: [Track],
        candidateCount: Int
    ) -> YearDeterminationResult? {
        guard let dominant = validator.getDominantYear(tracks: albumTracks),
              !dominant.isSuspicious
        else {
            return nil
        }

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

    /// Returns valid release-year consensus without consulting dominant years or external candidates.
    public func consensusDetermination(
        albumTracks: [Track],
        candidateCount: Int
    ) -> YearDeterminationResult? {
        guard !albumTracks.isEmpty,
              let consensus = validator.getConsensusReleaseYear(tracks: albumTracks),
              case .valid = validator.validate(year: consensus)
        else {
            return nil
        }

        return YearDeterminationResult(
            yearResult: YearResult(
                year: consensus,
                isDefinitive: true,
                confidence: validator.config.consensusYearConfidence
            ),
            source: .consensus,
            candidateCount: candidateCount
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
