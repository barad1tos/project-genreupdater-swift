// YearFallbackStrategy.swift — Decision tree for year update fallback

import Foundation

/// Resolves a scored API year against existing and read-only album evidence.
public struct YearFallbackStrategy: Sendable {
    public let config: FallbackConfig
    public let yearLogic: YearLogicConfig

    public init(
        config: FallbackConfig = FallbackConfig(),
        yearLogic: YearLogicConfig = YearLogicConfig()
    ) {
        self.config = config
        self.yearLogic = yearLogic
    }

    /// Resolves the final year and optional pending-verification mutation.
    public func evaluate(_ context: FallbackContext) -> YearFallbackOutcome {
        guard let proposedYear = context.bestYear, context.bestScore > 0 else {
            return noCandidateOutcome(context)
        }
        if let preliminary = preliminaryOutcome(context, proposedYear: proposedYear) {
            return preliminary
        }
        guard let existingYear = context.existingYear else {
            return apiOutcome(year: proposedYear, score: context.bestScore)
        }
        if let specialOutcome = specialAlbumOutcome(
            context,
            proposedYear: proposedYear,
            existingYear: existingYear
        ) {
            return specialOutcome
        }
        return existingYearOutcome(
            context,
            proposedYear: proposedYear,
            existingYear: existingYear
        )
    }

    private func preliminaryOutcome(
        _ context: FallbackContext,
        proposedYear: Int
    ) -> YearFallbackOutcome? {
        guard config.enabled else {
            return apiOutcome(
                year: proposedYear,
                score: context.bestScore,
                decision: .noAction(reason: "Fallback disabled")
            )
        }
        if context.isDefinitive {
            return apiOutcome(year: proposedYear, score: context.bestScore)
        }
        if let existingYear = context.existingYear, existingYear == proposedYear {
            return matchingYearOutcome(context, year: proposedYear)
        }
        if proposedYear < yearLogic.absurdYearThreshold, context.existingYear == nil {
            return absurdYearOutcome(proposedYear: proposedYear)
        }
        if context.existingYear == nil,
           Double(context.bestScore) < yearLogic.minConfidenceForNewYear,
           context.verificationAttempts < config.maxVerificationAttempts {
            return lowConfidenceOutcome(context, proposedYear: proposedYear)
        }
        if let releaseYear = context.releaseYear,
           releaseYear == context.decisionYear,
           proposedYear < releaseYear {
            return freshReleaseOutcome(context, proposedYear: proposedYear, releaseYear: releaseYear)
        }
        return nil
    }

    private func absurdYearOutcome(proposedYear: Int) -> YearFallbackOutcome {
        YearFallbackOutcome(
            decision: .markAndSkip(reason: "Absurd year without existing metadata"),
            year: nil,
            source: .fallback,
            verification: .mark(
                reason: .absurdYearWithoutExisting,
                metadata: [
                    "absurd_threshold": String(yearLogic.absurdYearThreshold),
                    "confidence": "very_low",
                    "proposed_year": String(proposedYear),
                ]
            )
        )
    }

    private func lowConfidenceOutcome(
        _ context: FallbackContext,
        proposedYear: Int
    ) -> YearFallbackOutcome {
        YearFallbackOutcome(
            decision: .escalateToVerification(reason: "Very low confidence without existing metadata"),
            year: nil,
            source: .fallback,
            verification: .mark(
                reason: .veryLowConfidenceWithoutExisting,
                metadata: [
                    "confidence_score": String(context.bestScore),
                    "proposed_year": String(proposedYear),
                    "threshold": String(Int(yearLogic.minConfidenceForNewYear)),
                ]
            )
        )
    }

    private func freshReleaseOutcome(
        _ context: FallbackContext,
        proposedYear: Int,
        releaseYear: Int
    ) -> YearFallbackOutcome {
        YearFallbackOutcome(
            decision: .keepExisting(reason: "Fresh release year overrides stale API year"),
            year: releaseYear,
            source: .consensus,
            verification: .mark(
                reason: .noYearFound,
                metadata: [
                    "current_year": String(context.decisionYear),
                    "proposed_year": String(proposedYear),
                    "release_year": String(releaseYear),
                ]
            )
        )
    }

    private func noCandidateOutcome(_ context: FallbackContext) -> YearFallbackOutcome {
        guard let existingYear = context.existingYear else {
            return YearFallbackOutcome(
                decision: .noAction(reason: "No scored candidates"),
                year: nil,
                source: .fallback
            )
        }
        return YearFallbackOutcome(
            decision: .keepExisting(reason: "No candidates, keeping existing year"),
            year: existingYear,
            source: .library
        )
    }

    private func matchingYearOutcome(_ context: FallbackContext, year: Int) -> YearFallbackOutcome {
        guard let artistStartYear = context.artistStartYear, year < artistStartYear else {
            return YearFallbackOutcome(
                decision: .keepExisting(reason: "Existing and API years match"),
                year: year,
                source: .library
            )
        }
        return YearFallbackOutcome(
            decision: .markAndSkip(reason: "Matching year predates artist activity"),
            year: nil,
            source: .fallback,
            verification: .mark(
                reason: .implausibleMatchingYear,
                metadata: [
                    "artist_start_year": String(artistStartYear),
                    "note": "Both library and API returned same impossible year",
                    "plausibility": "year_before_artist_start",
                    "year": String(year),
                ]
            )
        )
    }

    private func specialAlbumOutcome(
        _ context: FallbackContext,
        proposedYear: Int,
        existingYear: Int
    ) -> YearFallbackOutcome? {
        guard let info = context.albumTypeInfo, info.albumType != .normal else { return nil }
        let verification = YearVerificationMutation.mark(
            reason: specialReason(for: info.albumType),
            metadata: [
                "album_type": info.albumType.rawValue,
                "confidence": "low",
                "detected_pattern": info.detectedPattern ?? "",
                "existing_year": String(existingYear),
                "proposed_year": String(proposedYear),
            ]
        )
        if info.strategy == .markAndSkip || isOldRerecording(
            info,
            proposedYear: proposedYear,
            decisionYear: context.decisionYear
        ) {
            return YearFallbackOutcome(
                decision: .markAndSkip(reason: "Special album preserves existing year"),
                year: existingYear,
                source: .library,
                verification: verification
            )
        }
        return YearFallbackOutcome(
            decision: .useAPIYear(year: proposedYear, confidence: context.bestScore),
            year: proposedYear,
            source: .api,
            verification: verification
        )
    }

    private func existingYearOutcome(
        _ context: FallbackContext,
        proposedYear: Int,
        existingYear: Int
    ) -> YearFallbackOutcome {
        if let conflict = releaseConflictOutcome(
            context,
            proposedYear: proposedYear,
            existingYear: existingYear
        ) {
            return conflict
        }
        let difference = abs(existingYear - proposedYear)
        guard difference > config.yearDifferenceThreshold else {
            return apiOutcome(year: proposedYear, score: context.bestScore)
        }
        if Double(context.bestScore) >= config.trustAPIScoreThreshold {
            return apiOutcome(year: proposedYear, score: context.bestScore)
        }
        if !context.yearScores.isEmpty, context.yearScores[existingYear] == nil {
            return apiOutcome(year: proposedYear, score: context.bestScore)
        }
        if let plausibility = artistPlausibilityOutcome(
            context,
            proposedYear: proposedYear,
            existingYear: existingYear
        ) {
            return plausibility
        }
        return preserveExisting(
            existingYear,
            decisionReason: "Suspicious dramatic year change",
            verificationReason: .suspiciousYearChange,
            metadata: [
                "confidence": "low",
                "confidence_score": String(context.bestScore),
                "existing_year": String(existingYear),
                "proposed_year": String(proposedYear),
                "year_difference": String(difference),
            ]
        )
    }

    private func releaseConflictOutcome(
        _ context: FallbackContext,
        proposedYear: Int,
        existingYear: Int
    ) -> YearFallbackOutcome? {
        guard let releaseYear = context.releaseYear,
              abs(releaseYear - proposedYear) > config.yearDifferenceThreshold
        else {
            return nil
        }
        return preserveExisting(
            existingYear,
            decisionReason: "API year conflicts with release year",
            verificationReason: .noYearFound,
            metadata: [
                "confidence_score": String(context.bestScore),
                "existing_year": String(existingYear),
                "note": "Apple Music release_year is read-only and more authoritative",
                "proposed_year": String(proposedYear),
                "release_year": String(releaseYear),
            ]
        )
    }

    private func artistPlausibilityOutcome(
        _ context: FallbackContext,
        proposedYear: Int,
        existingYear: Int
    ) -> YearFallbackOutcome? {
        guard let artistStartYear = context.artistStartYear else { return nil }
        if proposedYear < artistStartYear {
            return preserveExisting(
                existingYear,
                decisionReason: "Proposed year predates artist activity",
                verificationReason: .implausibleProposedYear,
                metadata: [
                    "confidence_score": String(context.bestScore),
                    "existing_year": String(existingYear),
                    "plausibility": "proposed_year_before_artist_start",
                    "proposed_year": String(proposedYear),
                ]
            )
        }
        guard existingYear < artistStartYear else { return nil }
        return YearFallbackOutcome(
            decision: .useAPIYear(year: proposedYear, confidence: context.bestScore),
            year: proposedYear,
            source: .api,
            verification: .mark(
                reason: .implausibleExistingYear,
                metadata: [
                    "confidence_score": String(context.bestScore),
                    "existing_year": String(existingYear),
                    "plausibility": "existing_year_impossible",
                    "proposed_year": String(proposedYear),
                ]
            )
        )
    }

    private func preserveExisting(
        _ existingYear: Int,
        decisionReason: String,
        verificationReason: YearVerificationReason,
        metadata: [String: String]
    ) -> YearFallbackOutcome {
        YearFallbackOutcome(
            decision: .keepExisting(reason: decisionReason),
            year: existingYear,
            source: .library,
            verification: .mark(reason: verificationReason, metadata: metadata)
        )
    }

    private func apiOutcome(
        year: Int,
        score: Int,
        decision: FallbackDecision? = nil
    ) -> YearFallbackOutcome {
        YearFallbackOutcome(
            decision: decision ?? .useAPIYear(year: year, confidence: score),
            year: year,
            source: .api
        )
    }

    private func specialReason(for albumType: AlbumType) -> YearVerificationReason {
        switch albumType {
        case .compilation: .specialCompilation
        case .reissue: .specialReissue
        case .special: .specialAlbum
        case .normal: .noYearFound
        }
    }

    private func isOldRerecording(
        _ info: AlbumTypeInfo,
        proposedYear: Int,
        decisionYear: Int
    ) -> Bool {
        guard info.detectedPattern == "re-record" || info.detectedPattern == "re-recorded" else {
            return false
        }
        return decisionYear - proposedYear >= config.rerecordingAgeYears
    }
}
