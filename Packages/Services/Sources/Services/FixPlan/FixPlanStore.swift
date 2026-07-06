import Foundation

public enum FixPlanPersistenceError: Error, LocalizedError, Sendable {
    case corruptedField(name: String, planID: UUID)
    case duplicatePlan(planID: UUID, revision: Int)
    case missingPlan(planID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .corruptedField(name, planID):
            "Failed to decode fix plan \(planID.uuidString): corrupted field \(name)"
        case let .duplicatePlan(planID, revision):
            "Fix plan \(planID.uuidString) revision \(revision) already exists; plans are immutable"
        case let .missingPlan(planID):
            "No fix plan stored for \(planID.uuidString)"
        }
    }
}

public enum FixPlanDecisionWriteResult: Equatable, Sendable {
    case saved(FixPlanReviewDecision)
    case conflict(current: FixPlanReviewDecision) // ADR 0011 rejected-stale substrate
}

public protocol FixPlanStore: Sendable {
    /// Insert-only: plans are immutable. Existing (planID, revision) throws
    /// duplicatePlan. Saves plan + initial decision in ONE transaction.
    func savePlan(_ plan: FixPlan, initialDecision: FixPlanReviewDecision) async throws
    func plan(id: FixPlanID, revision: FixPlanRevision) async throws -> FixPlan?
    /// Newest by createdAt, nil when none (Story 24). Corrupted rows throw loudly.
    func latestPlan() async throws -> FixPlan?
    func currentDecision(for planID: FixPlanID) async throws -> FixPlanReviewDecision?
    /// CAS: saved only when planRevision matches stored AND
    /// decision.revision == stored.revision.advanced(); else .conflict(current),
    /// no mutation. Missing plan throws missingPlan.
    func recordDecision(_ decision: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult
}
