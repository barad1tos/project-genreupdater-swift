import Foundation
import Services

extension AppDependencies {
    /// Display data for the retained write, if any — never the full request.
    func queuedWriteSummary() async -> ActivityQueuedWriteSummary? {
        guard let request = await runOrchestrator?.queuedWriteRequest(),
              let target = request.writeTarget
        else { return nil }
        return ActivityQueuedWriteSummary(
            planID: target.planID.rawValue.uuidString,
            isContinuation: request.continuesRunID != nil
        )
    }

    /// The queued-write freshness authority: the currently persisted decision
    /// triple for a plan. Store errors map to nil, so release fails closed as
    /// unverifiable and the queued intent is retained.
    func makeCurrentDecisionTarget() -> @Sendable (FixPlanID) async -> FixPlanWriteTarget? {
        { [weak self] planID in
            guard let store = await self?.fixPlanStore,
                  let decision = try? await store.currentDecision(for: planID)
            else { return nil }
            return FixPlanWriteTarget(
                planID: decision.planID,
                planRevision: decision.planRevision,
                decisionRevision: decision.revision
            )
        }
    }
}
