import Foundation

/// Freezes a preview run's proposed changes into an immutable fix plan
/// (ADR 0017).
public enum FixPlanCapture {
    /// Pure mapping — no determination logic. Returns `nil` for empty
    /// proposals: a no-fix analysis is a sync/no-op record, not a fix plan.
    public static func makePlan(
        from proposals: [ProposedChange],
        sourceRunID: RunID,
        scope: ProcessingScopeSnapshot,
        configuration: FixPlanConfig,
        createdAt: Date
    ) -> FixPlan? {
        guard !proposals.isEmpty else { return nil }

        let items = proposals.map { proposal in
            FixPlanItem(
                id: proposal.id,
                identity: FixPlanItemIdentity(
                    readID: proposal.track.id,
                    appleScriptID: proposal.track.appleScriptID,
                    artist: proposal.track.artist,
                    album: proposal.track.album,
                    trackName: proposal.track.name
                ),
                changeType: proposal.changeType,
                oldValue: proposal.oldValue,
                newValue: proposal.newValue,
                confidence: proposal.confidence,
                source: proposal.source
            )
        }

        return FixPlan(
            id: FixPlanID(),
            revision: .initial,
            sourceRunID: sourceRunID,
            createdAt: createdAt,
            configuration: configuration,
            scope: scope,
            items: items
        )
    }
}
