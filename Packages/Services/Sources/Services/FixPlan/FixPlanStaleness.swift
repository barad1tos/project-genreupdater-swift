import Foundation

/// A single reason a captured fix plan no longer matches the current run
/// context.
public enum FixPlanStalenessReason: Equatable, Sendable {
    case scopeChanged
    case configurationChanged
}

/// Evaluated-on-read staleness of a captured fix plan (ADR 0017).
///
/// A plan is a snapshot of what the user was shown; it never mutates. This
/// type answers, at the moment of review, whether the scope or configuration
/// that produced it still matches the current run context.
public struct FixPlanStaleness: Equatable, Sendable {
    public let reasons: [FixPlanStalenessReason]

    public var isStale: Bool {
        !reasons.isEmpty
    }

    /// Scope comparison is deliberately narrower than the full scope fingerprint.
    /// `knownTrackCount` changes do not stale a plan, while a Test Artists matching-rule
    /// change does because it changes which tracks the plan can include.
    public static func evaluate(
        plan: FixPlan,
        currentScope: ProcessingScopeSnapshot,
        currentConfiguration: FixPlanConfig
    ) -> Self {
        var reasons: [FixPlanStalenessReason] = []

        let ruleChanged = plan.scope.source == .testArtists &&
            plan.scope.matchingRule != currentScope.matchingRule
        let scopeChanged = plan.scope.source != currentScope.source ||
            plan.scope.normalizedTestArtists != currentScope.normalizedTestArtists ||
            ruleChanged
        if scopeChanged {
            reasons.append(.scopeChanged)
        }

        if plan.configuration.fingerprint != currentConfiguration.fingerprint {
            reasons.append(.configurationChanged)
        }

        return Self(reasons: reasons)
    }
}
