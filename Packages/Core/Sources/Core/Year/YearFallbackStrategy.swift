// YearFallbackStrategy.swift — Decision tree for year update fallback
// Ported from: year_fallback.py (871 LOC)
//
// Pure struct (TDD Decision 9). Evaluates context to decide whether
// to use API year, keep existing, escalate, or skip.

import Foundation

// MARK: - YearFallbackStrategy

/// Decides how to handle year updates when scoring alone isn't sufficient.
///
/// 8-rule decision tree (first match wins):
/// 1. Definitive API result → USE_API_YEAR
/// 2. Absurd year + no existing → USE_API_YEAR
/// 3. Existing matches API → KEEP_EXISTING
/// 4. Low confidence → ESCALATE_TO_VERIFICATION
/// 5. Fresh album (dateAdded < 1 year) → USE_API_YEAR
/// 6. No existing year → USE_API_YEAR
/// 7. Special album type → MARK_AND_SKIP
/// 8. Dramatic year change → ESCALATE_TO_VERIFICATION
public struct YearFallbackStrategy: Sendable {
    public let config: FallbackConfig
    public let yearLogic: YearLogicConfig

    /// Maximum verification attempts before giving up.
    public static let maxVerificationAttempts = 3

    public init(
        config: FallbackConfig = FallbackConfig(),
        yearLogic: YearLogicConfig = YearLogicConfig()
    ) {
        self.config = config
        self.yearLogic = yearLogic
    }

    // MARK: - Decision

    /// Evaluate context and return a fallback decision.
    ///
    /// Rules are evaluated in order; the first matching rule wins.
    /// If no rule matches, returns `.noAction`.
    public func decide(_ context: FallbackContext) -> FallbackDecision {
        guard config.enabled else {
            return .noAction(reason: "Fallback disabled")
        }

        guard let bestYear = context.bestYear,
              context.bestScore > 0 else {
            return .noAction(reason: "No scored candidates")
        }

        return applyRules(context, bestYear: bestYear)
    }

    // MARK: - Rule Chain

    private func applyRules(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision {
        if let r = ruleDefinitive(ctx, bestYear: bestYear) { return r }
        if let r = ruleAbsurd(ctx, bestYear: bestYear) { return r }
        if let r = ruleMatch(ctx, bestYear: bestYear) { return r }
        if let r = ruleLowConfidence(ctx) { return r }
        if let r = ruleFresh(ctx, bestYear: bestYear) { return r }
        if let r = ruleNoExisting(ctx, bestYear: bestYear) { return r }
        if let r = ruleSpecialAlbum(ctx) { return r }
        if let r = ruleDramaticChange(ctx, bestYear: bestYear) { return r }

        return .useAPIYear(
            year: bestYear, confidence: ctx.bestScore
        )
    }

    private func ruleDefinitive(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard ctx.isDefinitive else { return nil }
        return .useAPIYear(
            year: bestYear, confidence: ctx.bestScore
        )
    }

    private func ruleAbsurd(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard let existing = ctx.existingYear,
              existing < yearLogic.minValidYear else {
            return nil
        }
        return .useAPIYear(
            year: bestYear, confidence: ctx.bestScore
        )
    }

    private func ruleMatch(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard let existing = ctx.existingYear,
              existing == bestYear else { return nil }
        return .keepExisting(
            reason: "Existing year \(existing) matches API"
        )
    }

    private func ruleLowConfidence(
        _ ctx: FallbackContext
    ) -> FallbackDecision? {
        guard Double(ctx.bestScore)
            < config.trustAPIScoreThreshold else {
            return nil
        }
        if ctx.verificationAttempts
            < Self.maxVerificationAttempts {
            return .escalateToVerification(
                reason: "Score \(ctx.bestScore) below "
                    + "threshold "
                    + "\(Int(config.trustAPIScoreThreshold))"
            )
        }
        return .noAction(
            reason: "Max verification attempts reached"
        )
    }

    private func ruleFresh(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard isFreshAlbum(ctx.track) else { return nil }
        return .useAPIYear(
            year: bestYear, confidence: ctx.bestScore
        )
    }

    private func ruleNoExisting(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard ctx.existingYear == nil else { return nil }
        return .useAPIYear(
            year: bestYear, confidence: ctx.bestScore
        )
    }

    private func ruleSpecialAlbum(
        _ ctx: FallbackContext
    ) -> FallbackDecision? {
        guard let albumInfo = ctx.albumTypeInfo,
              albumInfo.strategy == .markAndSkip else {
            return nil
        }
        return .markAndSkip(
            reason: "Special album type: "
                + "\(albumInfo.albumType.rawValue)"
                + (albumInfo.detectedPattern
                    .map { " (\($0))" } ?? "")
        )
    }

    /// Rule 8: Dramatic year change cascade (8a–8e).
    /// Ported from Python `_handle_dramatic_year_change`.
    private func ruleDramaticChange(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard let existing = ctx.existingYear else {
            return nil
        }
        let diff = abs(bestYear - existing)
        guard diff > config.yearDifferenceThreshold else {
            return nil
        }

        // 8a: High confidence → trust API
        if Double(ctx.bestScore)
            >= config.trustAPIScoreThreshold {
            return .useAPIYear(
                year: bestYear, confidence: ctx.bestScore
            )
        }
        // 8b: Existing year is absurd → trust API
        if existing < yearLogic.absurdYearThreshold {
            return .useAPIYear(
                year: bestYear, confidence: ctx.bestScore
            )
        }
        // 8c: Proposed year is absurd → keep existing
        if bestYear < yearLogic.absurdYearThreshold {
            return .keepExisting(
                reason: "API year \(bestYear) is absurd,"
                    + " keeping \(existing)"
            )
        }
        // 8d: Existing has no support → trust API
        let existingInResults = ctx.scoredReleases
            .contains { $0.candidate.year == existing }
        if !existingInResults
            && !ctx.scoredReleases.isEmpty {
            return .useAPIYear(
                year: bestYear, confidence: ctx.bestScore
            )
        }
        // 8e: Default → escalate
        if ctx.verificationAttempts
            < Self.maxVerificationAttempts {
            return .escalateToVerification(
                reason: "Year change \(existing)→\(bestYear)"
                    + " (diff \(diff) > threshold "
                    + "\(config.yearDifferenceThreshold))"
            )
        }
        return .keepExisting(
            reason: "Max verification attempts reached"
                + " for dramatic change"
        )
    }

    // MARK: - Helpers

    /// Check if a track was added within the last year.
    private func isFreshAlbum(_ track: Track) -> Bool {
        guard let dateAdded = track.dateAdded else { return false }
        let oneYearAgo = Calendar.current.date(
            byAdding: .year, value: -1, to: Date()
        ) ?? Date.distantPast
        return dateAdded > oneYearAgo
    }
}
