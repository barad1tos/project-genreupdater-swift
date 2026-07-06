import Foundation

/// Pure builders for fix-plan review decisions (ADR 0017).
///
/// Every transform produces a new `FixPlanReviewDecision` — the immutable
/// replacement for `ChangePreviewPipeline`'s `inout` mutations. None of these
/// mutate the plan or a prior decision; each successor advances
/// `revision` by exactly one while carrying `planID`/`planRevision` forward
/// unchanged.
public enum FixPlanReviewer {
    /// The starting decision for a freshly captured plan: every item
    /// accepted, at `ReviewDecisionRevision.initial`.
    public static func initialDecision(for plan: FixPlan, at decidedAt: Date) -> FixPlanReviewDecision {
        FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: .initial,
            decidedAt: decidedAt,
            itemDecisions: plan.items.map { FixPlanItemDecision(itemID: $0.id, verdict: .accepted) }
        )
    }

    public static func acceptingAll(_ decision: FixPlanReviewDecision, at decidedAt: Date) -> FixPlanReviewDecision {
        successor(to: decision, at: decidedAt) { itemDecisions in
            itemDecisions.map { FixPlanItemDecision(itemID: $0.itemID, verdict: .accepted) }
        }
    }

    public static func rejectingAll(_ decision: FixPlanReviewDecision, at decidedAt: Date) -> FixPlanReviewDecision {
        successor(to: decision, at: decidedAt) { itemDecisions in
            itemDecisions.map { FixPlanItemDecision(itemID: $0.itemID, verdict: .rejected) }
        }
    }

    /// `nil` when `itemID` is not part of the decision — unknown items are a
    /// stale-UI signal, not a silent no-op.
    public static func togglingItem(
        _ itemID: UUID,
        in decision: FixPlanReviewDecision,
        at decidedAt: Date
    ) -> FixPlanReviewDecision? {
        guard decision.itemDecisions.contains(where: { $0.itemID == itemID }) else { return nil }

        return successor(to: decision, at: decidedAt) { itemDecisions in
            itemDecisions.map { itemDecision in
                guard itemDecision.itemID == itemID else { return itemDecision }
                let flippedVerdict: FixPlanItemVerdict = itemDecision.verdict == .accepted ? .rejected : .accepted
                return FixPlanItemDecision(itemID: itemDecision.itemID, verdict: flippedVerdict)
            }
        }
    }

    private static func successor(
        to decision: FixPlanReviewDecision,
        at decidedAt: Date,
        transform: ([FixPlanItemDecision]) -> [FixPlanItemDecision]
    ) -> FixPlanReviewDecision {
        FixPlanReviewDecision(
            planID: decision.planID,
            planRevision: decision.planRevision,
            revision: decision.revision.advanced(),
            decidedAt: decidedAt,
            itemDecisions: transform(decision.itemDecisions)
        )
    }
}
