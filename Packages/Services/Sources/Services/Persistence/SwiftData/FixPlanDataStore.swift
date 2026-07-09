import Foundation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.genreupdater", category: "FixPlanStore")

/// Single-writer assumption: `#Unique` upserts silently instead of throwing, so
/// plan immutability holds only while one store instance owns the container.
/// A second context racing past the duplicate probe could overwrite a row.
@ModelActor
public actor FixPlanDataStore: FixPlanStore {
    /// The store trusts the caller triple: `FixPlanReviewer.initialDecision(for:at:)`
    /// is the only producer of initial decisions and structurally guarantees
    /// `initialDecision.planID == plan.id` and `planRevision == plan.revision`.
    /// A mismatch is a programmer error with no matching `FixPlanPersistenceError`
    /// case, so it is a documented contract rather than a runtime check.
    public func savePlan(_ plan: FixPlan, initialDecision: FixPlanReviewDecision) async throws {
        assert(
            initialDecision.planID == plan.id && initialDecision.planRevision == plan.revision,
            "savePlan initial decision must reference the plan being saved"
        )
        let targetPlanID = plan.id.rawValue
        let targetRevision = plan.revision.value
        try validateItemAlignment(of: initialDecision, with: plan.items, planID: targetPlanID)

        // SwiftData unique constraints upsert instead of throwing, so the
        // immutability guarantee needs an explicit duplicate probe.
        var duplicateProbe = FetchDescriptor<PersistedFixPlan>(
            predicate: #Predicate { $0.planID == targetPlanID && $0.revision == targetRevision }
        )
        duplicateProbe.fetchLimit = 1
        guard try modelContext.fetch(duplicateProbe).isEmpty else {
            throw FixPlanPersistenceError.duplicatePlan(planID: targetPlanID, revision: targetRevision)
        }

        try modelContext.insert(makePersisted(from: plan))

        // A new revision of an existing plan supersedes its current decision;
        // both writes land in the single save below so a plan without a
        // decision is unrepresentable.
        if let decisionRow = try fetchDecisionRow(planID: targetPlanID) {
            // The reset is deliberate, but a user's in-progress review vanishes
            // here — leave lineage evidence (IDs, revisions, counts are not
            // user metadata).
            log.info("""
            Fix plan \(targetPlanID.uuidString, privacy: .public) revision \(targetRevision, privacy: .public) \
            supersedes decision revision \(decisionRow.decisionRevision, privacy: .public) \
            for plan revision \(decisionRow.planRevision, privacy: .public)
            """)
            try apply(initialDecision, to: decisionRow)
        } else {
            try modelContext.insert(makePersisted(from: initialDecision))
        }
        try saveOrRollback()
    }

    public func plan(id: FixPlanID, revision: FixPlanRevision) async throws -> FixPlan? {
        let targetPlanID = id.rawValue
        let targetRevision = revision.value
        var descriptor = FetchDescriptor<PersistedFixPlan>(
            predicate: #Predicate { $0.planID == targetPlanID && $0.revision == targetRevision }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try makePlan(from: $0) }
    }

    public func latestPlan() async throws -> FixPlan? {
        var descriptor = FetchDescriptor<PersistedFixPlan>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        // A corrupted newest row throws loudly (Story 24): silently falling back
        // to an older plan would present a stale proposal as current.
        return try modelContext.fetch(descriptor).first.map { try makePlan(from: $0) }
    }

    public func currentDecision(for planID: FixPlanID) async throws -> FixPlanReviewDecision? {
        try fetchDecisionRow(planID: planID.rawValue).map { try makeDecision(from: $0) }
    }

    public func recordDecision(_ decision: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        let targetPlanID = decision.planID.rawValue

        var planProbe = FetchDescriptor<PersistedFixPlan>(
            predicate: #Predicate { $0.planID == targetPlanID }
        )
        planProbe.fetchLimit = 1
        guard try !modelContext.fetch(planProbe).isEmpty else {
            throw FixPlanPersistenceError.missingPlan(planID: targetPlanID)
        }

        guard let decisionRow = try fetchDecisionRow(planID: targetPlanID) else {
            // savePlan writes plan and initial decision in one transaction, so a
            // plan without a decision row is a corrupted store, not a fresh one.
            throw FixPlanPersistenceError.corruptedField(name: "decision", planID: targetPlanID)
        }
        let storedDecision = try makeDecision(from: decisionRow)

        let matchesPlanRevision = decision.planRevision.value == decisionRow.planRevision
        // Overflow-safe: a corrupted row holding Int.max must conflict, not trap.
        let (expectedSuccessor, overflowed) = decisionRow.decisionRevision.addingReportingOverflow(1)
        let isImmediateSuccessor = !overflowed && decision.revision.value == expectedSuccessor
        guard matchesPlanRevision, isImmediateSuccessor else {
            return .conflict(current: storedDecision)
        }

        // Decisions can be assembled at the UI boundary via the public init,
        // so the store is the last line against verdicts for items the plan
        // never proposed. The plan row for this revision exists whenever the
        // CAS guard passes (savePlan atomicity).
        let planItems = try fetchPlanItems(planID: targetPlanID, revision: decisionRow.planRevision)
        try validateItemAlignment(of: decision, with: planItems, planID: targetPlanID)

        try apply(decision, to: decisionRow)
        try saveOrRollback()
        return .saved(decision)
    }

    private func fetchPlanItems(planID: UUID, revision: Int) throws -> [FixPlanItem] {
        var descriptor = FetchDescriptor<PersistedFixPlan>(
            predicate: #Predicate { $0.planID == planID && $0.revision == revision }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else {
            throw FixPlanPersistenceError.missingPlan(planID: planID)
        }
        return try decodeBlob([FixPlanItem].self, from: row.itemsData, field: "items", planID: planID)
    }

    private func validateItemAlignment(
        of decision: FixPlanReviewDecision,
        with planItems: [FixPlanItem],
        planID: UUID
    ) throws {
        let decisionItemIDs = decision.itemDecisions.map(\.itemID)
        guard decisionItemIDs.count == planItems.count,
              Set(decisionItemIDs) == Set(planItems.map(\.id))
        else {
            throw FixPlanPersistenceError.invalidDecisionItems(planID: planID)
        }
    }

    /// A failed save leaves pending mutations in the context; without rollback a
    /// retry would probe against unpersisted rows and a later unrelated save
    /// would flush a write the caller was told failed.
    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func fetchDecisionRow(planID: UUID) throws -> PersistedFixPlanDecision? {
        var descriptor = FetchDescriptor<PersistedFixPlanDecision>(
            predicate: #Predicate { $0.planID == planID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func makePersisted(from plan: FixPlan) throws -> PersistedFixPlan {
        try PersistedFixPlan(
            planID: plan.id.rawValue,
            revision: plan.revision.value,
            sourceRunID: plan.sourceRunID.rawValue,
            createdAt: plan.createdAt,
            configSnapshotData: JSONEncoder().encode(plan.configuration),
            scopeSnapshotData: JSONEncoder().encode(plan.scope),
            itemsData: JSONEncoder().encode(plan.items),
            itemCount: plan.items.count,
            scopeSource: plan.scope.source.rawValue,
            configFingerprint: plan.configuration.fingerprint
        )
    }

    private func makePersisted(from decision: FixPlanReviewDecision) throws -> PersistedFixPlanDecision {
        try PersistedFixPlanDecision(
            planID: decision.planID.rawValue,
            planRevision: decision.planRevision.value,
            decisionRevision: decision.revision.value,
            decidedAt: decision.decidedAt,
            itemDecisionsData: JSONEncoder().encode(decision.itemDecisions)
        )
    }

    private func apply(_ decision: FixPlanReviewDecision, to row: PersistedFixPlanDecision) throws {
        // Encode before mutating so a throwing encode cannot leave the row
        // half-updated in the pending context.
        let itemDecisionsData = try JSONEncoder().encode(decision.itemDecisions)
        row.planRevision = decision.planRevision.value
        row.decisionRevision = decision.revision.value
        row.decidedAt = decision.decidedAt
        row.itemDecisionsData = itemDecisionsData
    }

    private func makePlan(from persisted: PersistedFixPlan) throws -> FixPlan {
        try FixPlan(
            id: FixPlanID(rawValue: persisted.planID),
            revision: FixPlanRevision(persisted.revision),
            sourceRunID: RunID(rawValue: persisted.sourceRunID),
            createdAt: persisted.createdAt,
            configuration: decodeBlob(
                FixPlanConfigurationSnapshot.self,
                from: persisted.configSnapshotData,
                field: "configuration",
                planID: persisted.planID
            ),
            scope: decodeBlob(
                ProcessingScopeSnapshot.self,
                from: persisted.scopeSnapshotData,
                field: "scope",
                planID: persisted.planID
            ),
            items: decodeBlob(
                [FixPlanItem].self,
                from: persisted.itemsData,
                field: "items",
                planID: persisted.planID
            )
        )
    }

    private func makeDecision(from persisted: PersistedFixPlanDecision) throws -> FixPlanReviewDecision {
        try FixPlanReviewDecision(
            planID: FixPlanID(rawValue: persisted.planID),
            planRevision: FixPlanRevision(persisted.planRevision),
            revision: ReviewDecisionRevision(persisted.decisionRevision),
            decidedAt: persisted.decidedAt,
            itemDecisions: decodeBlob(
                [FixPlanItemDecision].self,
                from: persisted.itemDecisionsData,
                field: "itemDecisions",
                planID: persisted.planID
            )
        )
    }

    private func decodeBlob<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        field: String,
        planID: UUID
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Decode details stay private: blobs embed user artist/track/album names.
            log.error("""
            Corrupted \(field, privacy: .public) blob in fix plan \(planID.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            throw FixPlanPersistenceError.corruptedField(name: field, planID: planID)
        }
    }
}
