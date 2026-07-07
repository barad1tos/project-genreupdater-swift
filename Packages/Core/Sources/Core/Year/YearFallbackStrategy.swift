// YearFallbackStrategy.swift — Decision tree for year update fallback
// Ported from: year_fallback.py (871 LOC)
//
// Pure struct (TDD Decision 9). Evaluates context to decide whether
// to use API year, keep existing, escalate, or skip.

import Foundation

// MARK: - YearFallbackStrategy

/// Decides how to handle year updates when scoring alone isn't sufficient.
///
/// Python-parity decision tree (first match wins):
/// 1. Definitive API result → USE_API_YEAR
/// 2. No candidates: has existing → KEEP_EXISTING; no existing → NO_ACTION
/// 3. Special album type → MARK_AND_SKIP
/// 4. Max verification attempts → USE_API_YEAR
/// 5. Has existing + close diff → KEEP_EXISTING
/// 6. Has existing + large diff + low confidence → KEEP_EXISTING
/// 7. Has existing + large diff + high confidence → USE_API_YEAR
/// 8. No existing + low confidence → ESCALATE_TO_VERIFICATION
/// 9. No existing + high confidence → USE_API_YEAR
/// 10. Default → USE_API_YEAR
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

    // MARK: - Decision

    /// Evaluate context and return a fallback decision.
    ///
    /// Rules are evaluated in order; the first matching rule wins.
    /// If no rule matches, returns `.useAPIYear`.
    public func decide(_ context: FallbackContext) -> FallbackDecision {
        guard config.enabled else {
            return .noAction(reason: "Fallback disabled")
        }

        // Rule 1: Definitive result always wins
        if context.isDefinitive, let bestYear = context.bestYear {
            return .useAPIYear(
                year: bestYear, confidence: context.bestScore
            )
        }

        // Rule 2: No candidates
        guard let bestYear = context.bestYear,
              context.bestScore > 0 else {
            if context.existingYear != nil {
                return .keepExisting(
                    reason: "No candidates, keeping existing year"
                )
            }
            return .noAction(reason: "No scored candidates")
        }

        return applyRules(context, bestYear: bestYear)
    }

    // MARK: - Rule Chain

    private func applyRules(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision {
        // Rule 3: Special album type (before confidence checks)
        if let result = ruleSpecialAlbum(ctx) {
            return result
        }

        // Rule 4: Max verification attempts → use best available
        if ctx.verificationAttempts >= config.maxVerificationAttempts {
            return .useAPIYear(
                year: bestYear, confidence: ctx.bestScore
            )
        }

        // Rules 5-7: Has existing year
        if let result = ruleWithExisting(ctx, bestYear: bestYear) {
            return result
        }

        // Rules 8-9: No existing year
        if ctx.existingYear == nil {
            if Double(ctx.bestScore) < config.trustAPIScoreThreshold {
                return .escalateToVerification(
                    reason: "Score \(ctx.bestScore) below "
                        + "threshold "
                        + "\(Int(config.trustAPIScoreThreshold))"
                )
            }
            return .useAPIYear(
                year: bestYear, confidence: ctx.bestScore
            )
        }

        // Rule 10: Default
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

    /// Rules for when an existing year is present.
    /// Close diff → keep; large diff + low confidence → keep;
    /// large diff + high confidence → use API.
    private func ruleWithExisting(
        _ ctx: FallbackContext, bestYear: Int
    ) -> FallbackDecision? {
        guard let existing = ctx.existingYear else { return nil }

        let diff = abs(bestYear - existing)

        // Rule 5: Close difference → keep existing
        if diff <= config.yearDifferenceThreshold {
            return .keepExisting(
                reason: "Year difference \(diff) within threshold"
            )
        }

        // Rule 6: Large diff + low confidence → keep existing
        if Double(ctx.bestScore) < config.trustAPIScoreThreshold {
            return .keepExisting(
                reason: "Low confidence \(ctx.bestScore) with"
                    + " large year change \(existing)→\(bestYear)"
            )
        }

        // Rule 7: Large diff + high confidence → use API
        return .useAPIYear(
            year: bestYear, confidence: ctx.bestScore
        )
    }
}
