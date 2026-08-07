import Core
import Foundation
import Testing
@testable import Services

@Suite("Chrome projection surface")
struct ChromeProjectionTests {
    @Test("the empty projection asserts nothing it cannot prove")
    func emptyProjectionAssertsNothing() {
        let empty = ChromeProjection.empty()

        #expect(empty.permissions == .unprobed)
        #expect(empty.permissions.isMusicAppAvailable == nil)
        #expect(empty.commands.isEmpty)
        #expect(empty.operationalIssues.isEmpty)
        #expect(empty.syncStatus.severity == .nominal)
        #expect(empty.syncStatus.isRunActive == false)
        #expect(empty.recoveryHold == nil)
        #expect(empty.effectiveScope == nil)
        #expect(empty.processingModeLabel == "Preview")
    }

    @Test("withRevision changes only the revision")
    func withRevisionChangesOnlyRevision() {
        let base = ChromeProjection.empty()
        let advanced = base.withRevision(ProjectionRevision(7))

        #expect(advanced.revision == ProjectionRevision(7))
        #expect(advanced.withRevision(base.revision) == base)
    }

    @Test("operational issues carry an optional next action")
    func operationalIssueCarriesNextAction() {
        let actionable = OperationalIssue(
            id: "settings-load",
            category: .configurationRequired,
            summary: "Settings could not be loaded.",
            nextAction: "Review and save Settings to repair the stored configuration."
        )
        let informational = OperationalIssue(
            id: "plain",
            category: .temporaryUnavailable,
            summary: "Service unavailable."
        )

        #expect(actionable.nextAction?.isEmpty == false)
        #expect(informational.nextAction == nil)
    }
}
