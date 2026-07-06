import Foundation

public enum FixPlanItemVerdict: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
}

public struct FixPlanItemDecision: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let verdict: FixPlanItemVerdict

    public init(itemID: UUID, verdict: FixPlanItemVerdict) {
        self.itemID = itemID
        self.verdict = verdict
    }
}

/// A versioned review decision applied to a specific fix plan revision (ADR 0017).
///
/// Write runs target the fix plan's `planID` + `planRevision` together with this
/// decision's own `revision`. Plans and decisions never mutate in place — a new
/// decision revision supersedes the last.
public struct FixPlanReviewDecision: Equatable, Sendable {
    public let planID: FixPlanID
    public let planRevision: FixPlanRevision
    public let revision: ReviewDecisionRevision
    public let decidedAt: Date
    /// Ordered array — deterministic JSON serialization.
    public let itemDecisions: [FixPlanItemDecision]

    public init(
        planID: FixPlanID,
        planRevision: FixPlanRevision,
        revision: ReviewDecisionRevision,
        decidedAt: Date,
        itemDecisions: [FixPlanItemDecision]
    ) {
        self.planID = planID
        self.planRevision = planRevision
        self.revision = revision
        self.decidedAt = decidedAt
        self.itemDecisions = itemDecisions
    }
}
