import Foundation
import Services
import Testing

@Suite("Command result model")
struct CommandResultTests {
    @Test("projection revision starts at initial value and advances")
    func projectionRevisionInitialAndAdvanced() {
        let revision = ProjectionRevision.initial

        #expect(revision.value == 0)
        #expect(revision.advanced() == ProjectionRevision(1))
    }

    @Test("projection revisions compare by value")
    func projectionRevisionsCompareByValue() {
        let currentRevision = ProjectionRevision(2)
        let newerRevision = ProjectionRevision(3)

        #expect(currentRevision < newerRevision)
        #expect(newerRevision > currentRevision)
        #expect(currentRevision <= ProjectionRevision(2))
    }

    @Test("run manually command carries stable identity")
    func runManuallyCarriesStableIdentity() {
        let id = UUID()
        let command = UserIntentCommand.runManually(id: id)

        #expect(command.id == id)
        #expect(command.kind == .runManually)
    }

    @Test("review changes command carries stable identity")
    func reviewChangesCarriesStableIdentity() {
        let id = UUID()
        let command = UserIntentCommand.reviewChanges(id: id)

        #expect(command.id == id)
        #expect(command.kind == .reviewChanges)
    }

    @Test("fix plan accept command carries target revisions")
    func fixPlanAcceptCarriesTargetRevisions() {
        let id = UUID()
        let planID = FixPlanID()
        let target = FixPlanCommandTarget(
            planID: planID,
            planRevision: FixPlanRevision(3),
            decisionRevision: ReviewDecisionRevision(5),
            projectionRevision: ProjectionRevision(7)
        )

        let command = UserIntentCommand.acceptFixPlan(target: target, id: id)

        #expect(command.id == id)
        #expect(command.kind == .acceptFixPlan)
        #expect(command.fixPlanTarget == target)
        #expect(command.fixPlanTarget?.planID == planID)
        #expect(command.targetItemID == nil)
    }

    @Test("fix plan apply command carries write target revisions")
    func applyCarriesRevisions() {
        let target = FixPlanCommandTarget(
            planID: FixPlanID(),
            planRevision: FixPlanRevision(3),
            decisionRevision: ReviewDecisionRevision(5),
            projectionRevision: ProjectionRevision(7)
        )

        let command = UserIntentCommand.applyFixPlan(target: target)

        #expect(command.kind == .applyFixPlan)
        #expect(command.fixPlanTarget == target)
        #expect(command.fixPlanTarget?.writeTarget.planRevision == FixPlanRevision(3))
        #expect(command.fixPlanTarget?.writeTarget.decisionRevision == ReviewDecisionRevision(5))
        #expect(command.targetItemID == nil)
    }

    @Test("fix plan item toggle command carries item target")
    func fixPlanToggleCarriesItemTarget() {
        let itemID = UUID()
        let target = FixPlanCommandTarget(
            planID: FixPlanID(),
            planRevision: FixPlanRevision(3),
            decisionRevision: ReviewDecisionRevision(5),
            projectionRevision: ProjectionRevision(7)
        )

        let command = UserIntentCommand.togglePlanItem(itemID, target: target)

        #expect(command.kind == .togglePlanItem)
        #expect(command.fixPlanTarget == target)
        #expect(command.targetItemID == itemID)
    }

    @Test("resume recovery command carries stable identity")
    func resumeRecoveryIdentity() {
        let id = UUID()
        let command = UserIntentCommand.resumeRecovery(id: id)

        #expect(command.id == id)
        #expect(command.kind == .resumeRecovery)
    }

    @Test("stale result carries refreshed activity projection")
    func staleResultCarriesRefreshedActivityProjection() {
        let projection = ActivityProjection.empty(revision: ProjectionRevision(9))
        let result = UserCommandResult.rejectedStale(
            message: "Activity changed. Refreshing current state.",
            refreshedActivityProjection: projection
        )

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Activity changed. Refreshing current state.")
        #expect(result.refreshedActivityProjection == projection)
        #expect(result.navigationTarget == nil)
    }

    @Test("navigation result exposes required navigation target")
    func navigationResultExposesRequiredNavigationTarget() {
        let target = CommandNavigationTarget.recovery(runID: "run-1")
        let result = UserCommandResult.navigated(message: "Opening recovery.", navigationTarget: target)

        #expect(result.status == .navigated)
        #expect(result.navigationTarget == target)
        #expect(result.issue == nil)
    }

    @Test("attention result exposes operational issue detail")
    func attentionResultExposesOperationalIssueDetail() {
        let issue = OperationalIssue(
            id: "library-sync-failed",
            category: .temporaryUnavailable,
            summary: "Library sync failed",
            technicalDetail: "Music.app returned an error"
        )

        let result = UserCommandResult.requiresAttention(
            message: "Library sync failed",
            issue: issue,
            refreshedActivityProjection: .empty(revision: ProjectionRevision(3))
        )

        #expect(result.status == .requiresAttention)
        #expect(result.issue == issue)
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(3))
    }
}
