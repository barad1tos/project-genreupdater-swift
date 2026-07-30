import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Queued-write consent wiring")
@MainActor
struct QueuedWriteWiringTests {
    @Test("the adapter returns the currently persisted decision triple")
    func returnsCurrentTriple() async throws {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })
        let planID = FixPlanID()
        let decision = FixPlanReviewDecision(
            planID: planID,
            planRevision: FixPlanRevision.initial.advanced(),
            revision: ReviewDecisionRevision.initial.advanced(),
            decidedAt: Date(timeIntervalSince1970: 100),
            itemDecisions: []
        )
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: DecisionStubStore(decision: decision)
        )

        let target = await dependencies.makeCurrentDecisionTarget()(planID)

        #expect(target == FixPlanWriteTarget(
            planID: planID,
            planRevision: decision.planRevision,
            decisionRevision: decision.revision
        ))
    }

    @Test("a failing store maps to nil so release stays fail-closed")
    func mapsStoreFailureToNil() async throws {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: DecisionStubStore(decision: nil, throws: true)
        )

        #expect(await dependencies.makeCurrentDecisionTarget()(FixPlanID()) == nil)
    }

    @Test("a missing store maps to nil")
    func mapsMissingStoreToNil() async throws {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })

        #expect(await dependencies.makeCurrentDecisionTarget()(FixPlanID()) == nil)
    }
}

private struct StubStoreFailure: Error {}

private struct DecisionStubStore: FixPlanStore {
    let decision: FixPlanReviewDecision?
    var throwsOnRead = false

    init(decision: FixPlanReviewDecision?, throws throwsOnRead: Bool = false) {
        self.decision = decision
        self.throwsOnRead = throwsOnRead
    }

    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {
        throw StubStoreFailure()
    }

    func plan(id _: FixPlanID, revision _: FixPlanRevision) async throws -> FixPlan? {
        nil
    }

    func latestPlan() async throws -> FixPlan? {
        nil
    }

    func currentDecision(for _: FixPlanID) async throws -> FixPlanReviewDecision? {
        if throwsOnRead {
            throw StubStoreFailure()
        }
        return decision
    }

    func recordDecision(_: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        throw StubStoreFailure()
    }
}
