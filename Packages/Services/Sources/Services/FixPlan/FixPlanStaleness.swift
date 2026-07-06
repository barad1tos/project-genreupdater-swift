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

    /// Scope comparison is deliberately narrow: only `source` and
    /// `normalizedTestArtists`, never the full scope fingerprint. The
    /// fingerprint embeds `knownTrackCount`, and ordinary library growth
    /// between capture and review must not stale a plan.
    public static func evaluate(
        plan: FixPlan,
        currentScope: ProcessingScopeSnapshot,
        currentConfiguration: FixPlanConfigurationSnapshot
    ) -> Self {
        var reasons: [FixPlanStalenessReason] = []

        let scopeChanged = plan.scope.source != currentScope.source ||
            plan.scope.normalizedTestArtists != currentScope.normalizedTestArtists
        if scopeChanged {
            reasons.append(.scopeChanged)
        }

        if plan.configuration.fingerprint != currentConfiguration.fingerprint {
            reasons.append(.configurationChanged)
        }

        return Self(reasons: reasons)
    }
}
