import Core
import Foundation
import Services

private let queuedWriteLog = AppLogger.make(category: "queuedWrite")

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
            guard let store = await self?.fixPlanStore else { return nil }
            do {
                guard let decision = try await store.currentDecision(for: planID) else { return nil }
                return FixPlanWriteTarget(
                    planID: decision.planID,
                    planRevision: decision.planRevision,
                    decisionRevision: decision.revision
                )
            } catch {
                // Fail closed as unverifiable, but leave the true cause in
                // the log — release keeps the slot either way.
                queuedWriteLog.error("""
                Consent lookup failed for plan \(planID.rawValue.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """)
                return nil
            }
        }
    }
}
