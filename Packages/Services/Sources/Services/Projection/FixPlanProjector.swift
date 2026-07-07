import Core
import Foundation

public enum FixPlanProjector {
    public static func makeProjection(
        plan: FixPlan,
        decision: FixPlanReviewDecision,
        staleness: FixPlanStaleness
    ) -> FixPlanProjection {
        let verdicts = Dictionary(
            uniqueKeysWithValues: decision.itemDecisions.map { ($0.itemID, $0.verdict) }
        )
        let items = plan.items.map { item in
            FixPlanProjectionItem(
                id: item.id,
                identity: FixPlanProjectionItem.Identity(
                    trackName: item.identity.trackName,
                    artist: item.identity.artist,
                    album: item.identity.album
                ),
                change: FixPlanProjectionItem.Change(
                    type: item.changeType,
                    oldValue: item.oldValue,
                    newValue: item.newValue,
                    confidence: item.confidence,
                    source: item.source
                ),
                verdict: verdicts[item.id] ?? .rejected
            )
        }
        let acceptedCount = items.count(where: { $0.verdict == .accepted })
        let status: FixPlanProjectionStatus = staleness.isStale ? .stale : .ready

        return FixPlanProjection(
            revision: .initial,
            status: status,
            lineage: FixPlanProjection.Lineage(
                planID: plan.id,
                planRevision: plan.revision,
                decisionRevision: decision.revision,
                sourceRunID: plan.sourceRunID
            ),
            summary: FixPlanProjection.Summary(
                itemCount: items.count,
                acceptedCount: acceptedCount,
                rejectedCount: items.count - acceptedCount,
                genreCount: items.count(where: { $0.changeType == .genreUpdate }),
                yearCount: items.count(where: { $0.changeType == .yearUpdate }),
                averageConfidence: averageConfidence(for: items),
                canApply: status == .ready && acceptedCount > 0
            ),
            stalenessReasons: staleness.reasons,
            items: items,
            operationalIssues: []
        )
    }

    private static func averageConfidence(for items: [FixPlanProjectionItem]) -> Int? {
        guard !items.isEmpty else { return nil }
        let total = items.reduce(0) { $0 + $1.confidence }
        return Int((Double(total) / Double(items.count)).rounded())
    }
}
