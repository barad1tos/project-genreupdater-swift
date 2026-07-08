import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityCommands recovery")
@MainActor
struct ActivityRecoveryTests {
    @Test("already active library check keeps recovery wording")
    func coversActiveCheck() async {
        let active = ActivityFixtures.lifecycle(phase: .active(.syncingLibrary))
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            runResult: .alreadyCovered(activeRun: active)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .alreadyCovered)
        #expect(result.message == "A library check is already active · writes remain held.")
        #expect((harness.submitRunCallCount, harness.reloadCallCount, harness.refreshCallCount) == (1, 0, 2))
    }

    @Test("library check queues with recovery wording")
    func queuesCheck() async {
        let active = ActivityFixtures.lifecycle(phase: .active(.syncingLibrary))
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            runResult: .queued(activeRun: active)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .queued)
        #expect(result.message == "Library check queued after current run.")
        #expect(harness.queuedReloadBarriers == [active.runID])
        #expect((harness.submitRunCallCount, harness.reloadCallCount, harness.refreshCallCount) == (1, 0, 2))
    }

    @Test("library check cancellation uses recovery wording")
    func cancelsCheck() async {
        let cancelled = ActivityFixtures.lifecycle(
            phase: .finished(.cancelled(message: "Run cancelled"), finishedAt: ActivityFixtures.finishDate)
        )
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            runResult: .cancelled(cancelled)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "Library check cancelled.")
        #expect((harness.submitRunCallCount, harness.reloadCallCount, harness.refreshCallCount) == (1, 0, 2))
    }
}
