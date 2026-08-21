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

private struct CandidateDecisionInput {
    let candidates: [ReleaseCandidate]
    let track: Track
    let albumTracks: [Track]
    let currentYear: Int?
    let artistActivityPeriod: (start: Int?, end: Int?)?
    let artistStartYear: Int?
    let artistCountry: String?
    let albumTypeInfo: AlbumTypeInfo?
    let verificationAttempts: Int
    let queryAlbum: String
    let decisionDate: Date
}

private struct CandidatePartition {
    let accepted: [ReleaseCandidate]
    let rejected: [ReleaseCandidate]
}

private struct DecisionEvidence {
    let outcome: YearFallbackOutcome
    let scoredResult: YearResult
    let scoredReleases: [ScoredRelease]
    let candidates: [ReleaseCandidate]
    let acceptedCandidates: [ReleaseCandidate]
    let rejectedCandidates: [ReleaseCandidate]
    let verificationMutations: [YearVerificationMutation]
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
    ///   - artistStartYear: Artist start used by fallback plausibility checks
    ///   - artistCountry: Artist's country code
    ///   - albumTypeInfo: Album classification result
    ///   - verificationAttempts: Previous escalation count
    ///   - queryAlbum: Album text used to score candidates when cleaning removed search evidence
    ///   - usesLocalEvidence: Whether dominant and consensus album metadata may bypass candidate scoring
    ///   - decisionDate: Date used for year bounds and current-year rules
    /// - Returns: Year determination result with source and breakdown
    public func determineYear(
        candidates: [ReleaseCandidate],
        track: Track,
        albumTracks: [Track] = [],
        currentYear: Int? = nil,
        artistActivityPeriod: (start: Int?, end: Int?)? = nil,
        artistStartYear: Int? = nil,
        artistCountry: String? = nil,
        albumTypeInfo: AlbumTypeInfo? = nil,
        verificationAttempts: Int = 0,
        queryAlbum: String? = nil,
        usesLocalEvidence: Bool = true,
        decisionDate: Date = Date()
    ) -> YearDeterminationResult {
        let signpostState = AppSignpost.yearDetermination.beginInterval("determineYear")
        defer { AppSignpost.yearDetermination.endInterval("determineYear", signpostState) }

        let storedYear = currentYear ?? track.year
        let effectiveCurrentYear = storedYear.flatMap { year in
            validator.acceptsCandidateYear(year, at: decisionDate) ? year : nil
        }

        // Steps 1-2: Cross-track year (dominant, consensus)
        if usesLocalEvidence, let result = checkCrossTrackYear(
            albumTracks: albumTracks,
            candidateCount: candidates.count
        ) {
            return result
        }
        guard !candidates.isEmpty else {
            return noResultDetermination(
                currentYear: effectiveCurrentYear,
                candidateCount: candidates.count,
                candidates: candidates
            )
        }

        return determineCandidateYear(
            CandidateDecisionInput(
                candidates: candidates,
                track: track,
                albumTracks: albumTracks,
                currentYear: effectiveCurrentYear,
                artistActivityPeriod: artistActivityPeriod,
                artistStartYear: artistStartYear,
                artistCountry: artistCountry,
                albumTypeInfo: albumTypeInfo,
                verificationAttempts: verificationAttempts,
                queryAlbum: queryAlbum ?? track.album,
                decisionDate: decisionDate
            )
        )
    }

    private func determineCandidateYear(_ input: CandidateDecisionInput) -> YearDeterminationResult {
        let partition = partitionCandidates(input.candidates, at: input.decisionDate)
        guard !partition.accepted.isEmpty else {
            return noResultDetermination(
                currentYear: input.currentYear,
                candidateCount: input.candidates.count,
                candidates: input.candidates
            )
        }
        let scored = partition.accepted.map { candidate in
            scorer.scoreRelease(
                candidate,
                queryArtist: AlbumIdentity.groupingArtist(for: input.track),
                queryAlbum: input.queryAlbum,
                currentYear: input.currentYear,
                artistActivityPeriod: input.artistActivityPeriod,
                artistCountry: input.artistCountry,
                decisionDate: input.decisionDate
            )
        }
        let scoredResult = scorer.resolveScores(
            scored,
            existingYear: input.currentYear,
            decisionDate: input.decisionDate
        )
        let existingAlbumYear = mostCommonYear(in: input.albumTracks) ?? input.currentYear
        var mutations = initialVerificationMutations(
            yearResult: scoredResult,
            existingYear: existingAlbumYear,
            verificationAttempts: input.verificationAttempts
        )
        let markedCount = mutations.count { mutation in
            if case .mark = mutation {
                true
            } else {
                false
            }
        }
        let fallbackContext = makeFallbackContext(
            input,
            scored: scored,
            scoredResult: scoredResult,
            existingYear: existingAlbumYear,
            verificationAttempts: input.verificationAttempts + markedCount
        )
        let outcome = fallback.evaluate(fallbackContext)
        if let mutation = outcome.verification {
            mutations.append(mutation)
        }
        return mapDecisionToResult(
            DecisionEvidence(
                outcome: outcome,
                scoredResult: scoredResult,
                scoredReleases: scored,
                candidates: input.candidates,
                acceptedCandidates: partition.accepted,
                rejectedCandidates: partition.rejected,
                verificationMutations: mutations
            )
        )
    }

    private func partitionCandidates(
        _ candidates: [ReleaseCandidate],
        at decisionDate: Date
    ) -> CandidatePartition {
        let accepted = candidates.filter {
            validator.acceptsCandidateYear($0.year, at: decisionDate)
        }
        let rejected = candidates.filter {
            !validator.acceptsCandidateYear($0.year, at: decisionDate)
        }
        return CandidatePartition(accepted: accepted, rejected: rejected)
    }

    private func makeFallbackContext(
        _ input: CandidateDecisionInput,
        scored: [ScoredRelease],
        scoredResult: YearResult,
        existingYear: Int?,
        verificationAttempts: Int
    ) -> FallbackContext {
        FallbackContext(
            scoredReleases: scored,
            existingYear: existingYear,
            track: input.track,
            albumTracks: input.albumTracks,
            isDefinitive: scoredResult.isDefinitive,
            bestScore: scoredResult.confidence,
            bestYear: scoredResult.year,
            albumTypeInfo: input.albumTypeInfo,
            verificationAttempts: verificationAttempts,
            releaseYear: validator.getConsensusReleaseYear(tracks: input.albumTracks),
            artistStartYear: input.artistStartYear ?? input.artistActivityPeriod?.start,
            decisionYear: currentUTCYear(at: input.decisionDate),
            yearScores: scoredResult.yearScores
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
        currentUTCYear(at: Date())
    }

    private func currentUTCYear(at date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.year, from: date)
    }

    // MARK: - Helpers

    private func noResultDetermination(
        currentYear: Int?,
        candidateCount: Int,
        candidates: [ReleaseCandidate]
    ) -> YearDeterminationResult {
        let verification = YearVerificationMutation.mark(
            reason: .noYearFound,
            metadata: [:]
        )
        if let year = currentYear {
            return YearDeterminationResult(
                yearResult: YearResult(
                    year: year,
                    isDefinitive: false,
                    confidence: 0
                ),
                source: .library,
                candidateCount: candidateCount,
                rejectedCandidateYears: candidates.map(\.year),
                verificationMutations: [verification]
            )
        }
        return YearDeterminationResult(
            yearResult: YearResult(),
            source: .fallback,
            candidateCount: candidateCount,
            rejectedCandidateYears: candidates.map(\.year),
            verificationMutations: [verification]
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

    private func mapDecisionToResult(_ evidence: DecisionEvidence) -> YearDeterminationResult {
        let bestBreakdown = evidence.scoredReleases
            .max(by: { $0.totalScore < $1.totalScore })?
            .breakdown

        let mapped = YearResult(
            year: evidence.outcome.year,
            isDefinitive: evidence.scoredResult.isDefinitive,
            confidence: evidence.scoredResult.confidence,
            rawScore: evidence.scoredResult.rawScore,
            yearScores: evidence.scoredResult.yearScores
        )
        let acceptedYears = evidence.acceptedCandidates.map(\.year)
        let rejectedYears = evidence.rejectedCandidates.map(\.year)

        return YearDeterminationResult(
            yearResult: mapped,
            scoredYearResult: evidence.scoredResult,
            source: evidence.outcome.source,
            breakdown: bestBreakdown,
            fallbackDecision: evidence.outcome.decision,
            candidateCount: evidence.candidates.count,
            acceptedCandidateYears: acceptedYears,
            rejectedCandidateYears: rejectedYears,
            verificationMutations: evidence.verificationMutations
        )
    }

    private func initialVerificationMutations(
        yearResult: YearResult,
        existingYear: Int?,
        verificationAttempts: Int
    ) -> [YearVerificationMutation] {
        if yearResult.isDefinitive {
            return [.remove]
        }
        if let selectedYear = yearResult.year,
           let existingYear,
           selectedYear == existingYear {
            return [.remove]
        }
        if verificationAttempts >= fallback.config.maxVerificationAttempts {
            return [.remove]
        }
        return [.mark(reason: .noYearFound, metadata: [:])]
    }

    private func mostCommonYear(in tracks: [Track]) -> Int? {
        var counts: [Int: Int] = [:]
        var order: [Int] = []
        for year in tracks.compactMap(\.year) {
            if counts[year] == nil {
                order.append(year)
            }
            counts[year, default: 0] += 1
        }
        return order.max { lhs, rhs in
            (counts[lhs] ?? 0) < (counts[rhs] ?? 0)
        }
    }
}
