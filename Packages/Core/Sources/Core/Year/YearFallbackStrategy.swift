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

        guard let bestYear = context.bestYear, context.bestScore > 0 else {
            return .noAction(reason: "No scored candidates")
        }

        // Rule 1: Definitive API result
        if context.isDefinitive {
            return .useAPIYear(
                year: bestYear,
                confidence: context.bestScore
            )
        }

        // Rule 2: Absurd existing year + API has result
        if let existing = context.existingYear, existing < yearLogic.minValidYear {
            return .useAPIYear(
                year: bestYear,
                confidence: context.bestScore
            )
        }

        // Rule 3: Existing matches API → keep
        if let existing = context.existingYear, existing == bestYear {
            return .keepExisting(
                reason: "Existing year \(existing) matches API"
            )
        }

        // Rule 4: Low confidence → escalate
        if Double(context.bestScore) < config.trustAPIScoreThreshold {
            if context.verificationAttempts
                < YearFallbackStrategy.maxVerificationAttempts {
                return .escalateToVerification(
                    reason: "Score \(context.bestScore) below "
                        + "threshold \(Int(config.trustAPIScoreThreshold))"
                )
            }
            return .noAction(
                reason: "Max verification attempts reached"
            )
        }

        // Rule 5: Fresh album (added within last year)
        if isFreshAlbum(context.track) {
            return .useAPIYear(
                year: bestYear,
                confidence: context.bestScore
            )
        }

        // Rule 6: No existing year → use API
        if context.existingYear == nil {
            return .useAPIYear(
                year: bestYear,
                confidence: context.bestScore
            )
        }

        // Rule 7: Special album type → mark and skip
        if let albumInfo = context.albumTypeInfo,
           albumInfo.strategy == .markAndSkip {
            return .markAndSkip(
                reason: "Special album type: "
                    + "\(albumInfo.albumType.rawValue)"
                    + (albumInfo.detectedPattern
                        .map { " (\($0))" } ?? "")
            )
        }

        // Rule 8: Dramatic year change → escalate
        if let existing = context.existingYear {
            let diff = abs(bestYear - existing)
            if diff > config.yearDifferenceThreshold {
                if context.verificationAttempts
                    < YearFallbackStrategy.maxVerificationAttempts {
                    return .escalateToVerification(
                        reason: "Year change \(existing)→\(bestYear)"
                            + " (diff \(diff) > threshold "
                            + "\(config.yearDifferenceThreshold))"
                    )
                }
                return .noAction(
                    reason: "Max verification attempts reached"
                        + " for dramatic change"
                )
            }
        }

        // Default: use API year (passed all guards)
        return .useAPIYear(
            year: bestYear,
            confidence: context.bestScore
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
