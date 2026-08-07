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

    @Test("store keeps the current chrome projection")
    func storeKeepsCurrentChromeProjection() async {
        let store = ProjectionStore()
        let published = await store.replaceChromeProjection(makeProbeProjection(title: "Probe"))

        let current = await store.currentChrome()

        #expect(current == published)
        #expect(current.shellTitle == "Probe")
    }

    @Test("each chrome replacement advances the projection revision")
    func chromeReplacementAdvancesRevision() async {
        let store = ProjectionStore()
        let first = await store.replaceChromeProjection(makeProbeProjection(title: "One"))
        let second = await store.replaceChromeProjection(makeProbeProjection(title: "Two"))

        #expect(second.revision != first.revision)
    }

    @Test("a content-identical chrome replacement preserves the revision")
    func contentIdenticalChromeReplacementPreservesRevision() async {
        let store = ProjectionStore()
        let first = await store.replaceChromeProjection(makeProbeProjection(title: "Same"))
        let second = await store.replaceChromeProjection(makeProbeProjection(title: "Same"))

        #expect(second.revision == first.revision)
    }

    @Test("an older chrome input generation cannot replace a newer projection")
    func olderChromeGenerationCannotReplaceNewer() async {
        let store = ProjectionStore()
        let staleGeneration = await store.nextChromeInputGeneration()
        let freshGeneration = await store.nextChromeInputGeneration()
        let fresh = await store.replaceChromeProjection(
            makeProbeProjection(title: "Fresh"),
            inputGeneration: freshGeneration
        )

        let afterStale = await store.replaceChromeProjection(
            makeProbeProjection(title: "Stale"),
            inputGeneration: staleGeneration
        )

        #expect(afterStale == fresh)
        #expect(afterStale.shellTitle == "Fresh")
    }

    @Test("the chrome updates stream yields the current projection on subscribe")
    func chromeUpdatesYieldCurrentOnSubscribe() async {
        let store = ProjectionStore()
        let published = await store.replaceChromeProjection(makeProbeProjection(title: "Streamed"))

        var iterator = await store.chromeUpdates().makeAsyncIterator()
        let first = await iterator.next()

        #expect(first == published)
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

private func makeProbeProjection(title: String) -> ChromeProjection {
    ChromeProjection(
        revision: .initial,
        shellTitle: title,
        shellSubtitle: nil,
        syncStatus: ChromeSyncStatus(text: "Idle", severity: .nominal, isRunActive: false),
        physicalTrackCount: 42,
        effectiveScope: nil,
        processingModeLabel: "Preview",
        automationState: .manualOnly,
        recoveryHold: nil,
        permissions: .unprobed,
        commands: [],
        operationalIssues: []
    )
}
