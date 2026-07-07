import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityCommandController")
@MainActor
struct ActivityCommandsTests {
    @Test("review changes command returns navigation result")
    func reviewChangesCommandReturnsNavigationResult() async {
        let harness = Harness(projection: makeReviewProjection(revision: ProjectionRevision(2)))
        let controller = harness.makeController()

        let result = await controller.handle(.reviewChanges())

        #expect(result.status == .navigated)
        #expect(result.message == "Opening review.")
        #expect(result.navigationTarget == .fixPlan(id: "plan-1"))
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(3))
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("review changes command rejects stale empty plan")
    func reviewChangesCommandRejectsStaleEmptyPlan() async {
        let harness = Harness(currentRevision: ProjectionRevision(2))
        let controller = harness.makeController()

        let result = await controller.handle(.reviewChanges())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Review plan is no longer available.")
        #expect(result.navigationTarget == nil)
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(3))
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("run manually command submits manual observation run")
    func runManuallyCommandSubmitsManualObservationRun() async {
        let harness = Harness(currentRevision: ProjectionRevision(2))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 1)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("already active run returns already covered")
    func alreadyActiveRunReturnsAlreadyCovered() async {
        let harness = Harness(runResult: .alreadyRunning(lifecycle(phase: .active(.syncingLibrary))))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .alreadyCovered)
        #expect(result.message == "A run is already active.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("run manually reports active run after stale guard refresh")
    func runManuallyReportsActiveRunAfterStaleGuardRefresh() async {
        let harness = Harness(marksRunActiveOnFirstRefresh: true)
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .alreadyCovered)
        #expect(result.message == "A run is already active.")
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("unavailable orchestrator returns temporary unavailable")
    func unavailableOrchestratorReturnsTemporaryUnavailable() async {
        let harness = Harness(isRunOrchestratorAvailable: false)
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .temporaryUnavailable)
        #expect(result.issue?.id == "run-orchestrator-unavailable")
        #expect(result.issue?.category == .temporaryUnavailable)
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("run manually rejects stale disabled command")
    func runManuallyRejectsStaleDisabledCommand() async {
        let harness = Harness(projection: makeRunManuallyProjection(
            revision: ProjectionRevision(2),
            isEnabled: false
        ))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Manual check is no longer available.")
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("review changes returns blocked by recovery for recovery hold")
    func reviewChangesReturnsBlockedByRecoveryForRecoveryHold() async {
        let harness = Harness(projection: makeRecoveryProjection(revision: ProjectionRevision(2)))
        let controller = harness.makeController()

        let result = await controller.handle(.reviewChanges())

        #expect(result.status == .blockedByRecovery)
        #expect(result.message == "Previous run needs recovery before writes continue.")
        #expect(result.issue?.id == "recovery-needed")
        #expect(result.issue?.category == .recoveryRequired)
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("resume recovery navigates to recovery notice")
    func resumeRecoveryNavigates() async {
        let harness = Harness(projection: makeRecoveryProjection(revision: ProjectionRevision(2)))
        let controller = harness.makeController()

        let result = await controller.handle(.resumeRecovery())

        #expect(result.status == .navigated)
        #expect(result.message == "Opening recovery.")
        #expect(result.navigationTarget == .recovery(runID: "run-1"))
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("primary resolver dispatches recovery command")
    func primaryDispatchesRecovery() {
        let command = ActivityCommandController.command(for: makeRecoveryProjection(
            revision: ProjectionRevision(2)
        ).primaryCommand)

        #expect(command?.kind == .resumeRecovery)
    }

    @Test("resume recovery reports library blocker")
    func recoveryReportsBlocker() async {
        let harness = Harness(projection: blockedRecoveryProjection(revision: ProjectionRevision(2)))
        let controller = harness.makeController()

        let result = await controller.handle(.resumeRecovery())

        #expect(result.status == .temporaryUnavailable)
        #expect(result.message == "Music permission required")
        #expect(result.issue?.category == .musicPermissionRequired)
        #expect(result.navigationTarget == nil)
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("run manually submits during recovery hold")
    func runManuallySubmitsDuringRecoveryHold() async {
        let harness = Harness(projection: makeRecoveryProjection(revision: ProjectionRevision(2)))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 1)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("completed no-op run reloads library and returns no-op")
    func completedNoOpRunReloadsLibraryAndReturnsNoOp() async {
        let harness = Harness(runResult: .completedNoOp(lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate)
        )))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 1)
    }

    @Test("completed run counts all delta arrays")
    func completedRunCountsAllDeltaArrays() async {
        let syncResult = SyncResult(
            newTracks: [track(id: "NEW")],
            modifiedTracks: [track(id: "MODIFIED")],
            identityChangedTracks: [track(id: "IDENTITY")],
            refreshedTracks: [track(id: "REFRESHED")],
            removedTrackIDs: ["REMOVED"]
        )
        let harness = Harness(
            runResult: .completed(lifecycle(phase: .finished(.completed(syncResult), finishedAt: finishDate)))
        )
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .accepted)
        #expect(result.message == "Library delta detected · analyzing 5 changes.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 1)
    }

    @Test("failed run returns requires attention")
    func failedRunReturnsRequiresAttention() async {
        let harness = Harness(runResult: .failed(lifecycle(phase: .finished(
            .failed(message: "Music.app is unavailable"),
            finishedAt: finishDate
        ))))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Manual check failed.")
        #expect(result.issue?.id == "manual-check-failed")
        #expect(result.issue?.summary == "Manual check failed")
        #expect(result.issue?.technicalDetail == "Music.app is unavailable")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
    }

    @Test("submit error returns requires attention")
    func submitErrorReturnsRequiresAttention() async {
        let harness = Harness(runError: TestError(message: "Run orchestrator crashed"))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.id == "manual-check-failed")
        #expect(result.issue?.category == .internalFailure)
        #expect(result.issue?.technicalDetail == "Run orchestrator crashed")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
    }

    private func track(id: String) -> Core.Track {
        Core.Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
    }

    private func makeReviewProjection(revision: ProjectionRevision) -> ActivityProjection {
        ActivityProjection(
            revision: revision,
            title: "Fix plan ready",
            subtitle: "2 candidate fixes",
            syncStatusText: "Synced just now",
            currentStage: .diff,
            processingMode: .preview,
            automationState: .manualScanOnly,
            deltaCount: 2,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: ActivityCommandDescriptor(
                id: "review-changes",
                title: "Review changes",
                style: .primary,
                isEnabled: true,
                commandKind: .reviewChanges
            ),
            secondaryCommand: nil,
            stageDescriptors: [],
            recentActivity: [],
            summaryCards: [],
            operationalIssues: []
        )
    }
}

private func makeRunManuallyProjection(
    revision: ProjectionRevision,
    isEnabled: Bool
) -> ActivityProjection {
    ActivityProjection(
        revision: revision,
        title: "Library ready",
        subtitle: "Library ready",
        syncStatusText: "Synced just now",
        currentStage: .detect,
        processingMode: .preview,
        automationState: .manualScanOnly,
        deltaCount: 0,
        interventionCount: 0,
        protectedCount: 0,
        failedWriteCount: 0,
        isUndoReady: false,
        primaryCommand: nil,
        secondaryCommand: ActivityCommandDescriptor(
            id: "run-manually",
            title: "Run manually",
            style: .secondary,
            isEnabled: isEnabled,
            commandKind: .runManually
        ),
        stageDescriptors: [],
        recentActivity: [],
        summaryCards: [],
        operationalIssues: []
    )
}

private func makeRecoveryProjection(revision: ProjectionRevision) -> ActivityProjection {
    ActivityProjection(
        revision: revision,
        title: "Recovery needed",
        subtitle: "Previous run needs recovery before writes continue",
        syncStatusText: "Recovery needed",
        currentStage: .fix,
        processingMode: .preview,
        automationState: .manualScanOnly,
        deltaCount: 0,
        interventionCount: 0,
        protectedCount: 0,
        failedWriteCount: 0,
        isUndoReady: false,
        primaryCommand: ActivityCommandDescriptor(
            id: "resume-recovery",
            title: "Resume safely",
            style: .primary,
            isEnabled: true,
            commandKind: .resumeRecovery
        ),
        secondaryCommand: ActivityCommandDescriptor(
            id: "run-manually",
            title: "Run manually",
            style: .secondary,
            isEnabled: true,
            commandKind: .runManually
        ),
        stageDescriptors: [],
        recentActivity: [],
        summaryCards: [],
        operationalIssues: [
            OperationalIssue(
                id: "recovery-needed",
                category: .recoveryRequired,
                summary: "Previous run needs recovery",
                technicalDetail: "run-1"
            ),
        ]
    )
}

private func blockedRecoveryProjection(revision: ProjectionRevision) -> ActivityProjection {
    ActivityProjection(
        revision: revision,
        title: "Library needs attention",
        subtitle: "Music access denied",
        syncStatusText: "Synced 8m ago",
        currentStage: .detect,
        processingMode: .preview,
        automationState: .manualScanOnly,
        deltaCount: 0,
        interventionCount: 0,
        protectedCount: 0,
        failedWriteCount: 0,
        isUndoReady: false,
        primaryCommand: nil,
        secondaryCommand: ActivityCommandDescriptor(
            id: "run-manually",
            title: "Run manually",
            style: .secondary,
            isEnabled: true,
            commandKind: .runManually
        ),
        stageDescriptors: [],
        recentActivity: [],
        summaryCards: [],
        operationalIssues: [
            OperationalIssue(
                id: "music-permission-required",
                category: .musicPermissionRequired,
                summary: "Music permission required",
                technicalDetail: "Music access denied"
            ),
        ]
    )
}

@MainActor
private final class Harness {
    var isRunOrchestratorAvailable: Bool
    var isRunActive: Bool
    var submitRunCallCount = 0
    var reloadCallCount = 0
    var refreshCallCount = 0

    private var projection: ActivityProjection
    private let runResult: RunSubmissionResult
    private let runError: Error?
    private let marksRunActiveOnFirstRefresh: Bool

    init(
        currentRevision: ProjectionRevision = ProjectionRevision(1),
        projection: ActivityProjection? = nil,
        isRunOrchestratorAvailable: Bool = true,
        isRunActive: Bool = false,
        marksRunActiveOnFirstRefresh: Bool = false,
        runResult: RunSubmissionResult? = nil,
        runError: Error? = nil
    ) {
        self.projection = projection ?? makeRunManuallyProjection(revision: currentRevision, isEnabled: true)
        self.isRunOrchestratorAvailable = isRunOrchestratorAvailable
        self.isRunActive = isRunActive
        self.marksRunActiveOnFirstRefresh = marksRunActiveOnFirstRefresh
        self.runResult = runResult ?? .completedNoOp(lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate)
        ))
        self.runError = runError
    }

    func makeController() -> ActivityCommandController {
        ActivityCommandController(
            isRunOrchestratorAvailable: { self.isRunOrchestratorAvailable },
            hasActiveRun: { self.isRunActive },
            submitManualObservationRun: {
                self.submitRunCallCount += 1
                if let runError = self.runError {
                    throw runError
                }
                return self.runResult
            },
            reloadLibrary: { forceRefresh in
                if forceRefresh {
                    self.reloadCallCount += 1
                }
            },
            refreshActivityProjection: {
                self.refreshCallCount += 1
                if self.marksRunActiveOnFirstRefresh {
                    self.isRunActive = true
                }
                self.projection = self.projection.withRevision(self.projection.revision.advanced())
                return self.projection
            },
            currentFixPlanID: {
                "plan-1"
            }
        )
    }
}

private let finishDate = Date(timeIntervalSince1970: 101)

private func lifecycle(phase: RunPhase) -> RunLifecycleSnapshot {
    RunLifecycleSnapshot(
        runID: RunID(),
        requestID: RunRequestID(),
        trigger: .manualCheck,
        intent: .observeLibrary,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 75,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "manualCheck"
        ),
        startedAt: Date(timeIntervalSince1970: 100),
        phase: phase
    )
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
