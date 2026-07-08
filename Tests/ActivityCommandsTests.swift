import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityCommands")
@MainActor
struct ActivityCommandsTests {
    @Test("review changes command returns navigation result")
    func reviewChangesCommandReturnsNavigationResult() async {
        let harness = Harness(projection: makeReviewProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.reviewChanges())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.reviewChanges())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 1)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("already active run returns already covered")
    func activeRunReturnsCovered() async {
        let harness = Harness(runResult: .alreadyCovered(activeRun: lifecycle(phase: .active(.syncingLibrary))))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .alreadyCovered)
        #expect(result.message == "A run is already active.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("queued manual run returns queued result")
    func manualRunReturnsQueued() async {
        let active = lifecycle(phase: .active(.syncingLibrary))
        let harness = Harness(runResult: .queued(activeRun: active))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .queued)
        #expect(result.message == "Manual check queued after current run.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.queuedReloadBarriers == [active.runID])
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("active background projection queues manual run")
    func backgroundQueuesManual() async {
        let active = lifecycle(phase: .active(.syncingLibrary), trigger: .backgroundSync)
        let harness = Harness(
            projection: makeActiveProjection(revision: ProjectionRevision(2), lifecycle: active),
            runResult: .queued(activeRun: active)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .queued)
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.queuedReloadBarriers == [active.runID])
        #expect(harness.reloadCallCount == 0)
    }

    @Test("unavailable orchestrator returns temporary unavailable")
    func unavailableOrchestratorReturnsTemporaryUnavailable() async {
        let harness = Harness(isRunOrchestratorAvailable: false)
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Manual check is no longer available.")
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("review changes returns blocked by recovery for recovery hold")
    func reviewChangesReturnsBlockedByRecoveryForRecoveryHold() async {
        let harness = Harness(projection: makeRecoveryProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.reviewChanges())

        #expect(result.status == .blockedByRecovery)
        #expect(result.message == "Previous run needs recovery before writes continue.")
        #expect(result.issue?.id == "recovery-needed")
        #expect(result.issue?.category == .recoveryRequired)
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("resume recovery runs preflight before navigation")
    func resumeRecoveryNavigates() async {
        let harness = Harness(projection: makeRecoveryProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .navigated)
        #expect(result.message == "Opening recovery.")
        #expect(result.navigationTarget == .recovery(runID: recoveryRunIDString))
        #expect(harness.preflightRunIDs == [recoveryRunID])
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("resume recovery resolves when preflight finds terminal record")
    func resolvedRecoveryNoOps() async {
        let harness = Harness(
            projection: makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .resolved(runID: recoveryRunID, reason: .alreadyFinished)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .noOp)
        #expect(result.message == "Recovery is no longer required.")
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs == [recoveryRunID])
        #expect(harness.refreshCallCount == 1)
    }

    @Test("resume recovery surfaces write-adjacent preflight attention")
    func writeAdjacentReview() async {
        let harness = Harness(
            projection: makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .needsAttention(runID: recoveryRunID, reason: .writeAdjacentState(.reporting))
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Recovery needs review.")
        #expect(result.issue?.id == "recovery-needs-attention")
        #expect(result.issue?.category == .safetyBlocked)
        #expect(result.issue?.technicalDetail == "reporting")
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs == [recoveryRunID])
    }

    @Test("resume recovery surfaces blocked preflight")
    func blockedNeedsAttention() async {
        let harness = Harness(
            projection: makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .blocked(runID: recoveryRunID, reason: .storeUnavailable)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Recovery preflight is unavailable.")
        #expect(result.issue?.id == "recovery-preflight-blocked")
        #expect(result.issue?.category == .temporaryUnavailable)
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs == [recoveryRunID])
    }

    @Test("resume recovery rejects malformed run id before preflight")
    func invalidIDBlocks() async {
        let harness = Harness(projection: makeRecoveryProjection(
            revision: ProjectionRevision(2),
            runID: "not-a-uuid"
        ))
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Recovery record is unavailable.")
        #expect(result.issue?.id == "recovery-record-unavailable")
        #expect(result.issue?.category == .recoveryRequired)
        #expect(result.issue?.technicalDetail == "not-a-uuid")
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs.isEmpty)
    }

    @Test("primary resolver dispatches recovery command")
    func primaryDispatchesRecovery() {
        let command = ActivityCommands.command(for: makeRecoveryProjection(
            revision: ProjectionRevision(2)
        ).primaryCommand)

        #expect(command?.kind == .resumeRecovery)
    }

    @Test("resume recovery reports library blocker")
    func recoveryReportsBlocker() async {
        let harness = Harness(projection: blockedRecoveryProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

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
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.id == "manual-check-failed")
        #expect(result.issue?.category == .internalFailure)
        #expect(result.issue?.technicalDetail == "Run orchestrator crashed")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
    }

    @Test("queued reload waits for queued manual terminal")
    func queuedReloadWaits() {
        let activeRunID = RunID()
        let activeTerminal = lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate),
            runID: activeRunID,
            trigger: .backgroundSync
        )

        let afterActive = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: activeTerminal)

        #expect(afterActive.next == .waitingForQueued)
        #expect(!afterActive.shouldReload)

        let queuedTerminal = lifecycle(phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate))
        let afterQueued = advanceQueuedReload(afterActive.next, lifecycle: queuedTerminal)

        #expect(afterQueued.next == nil)
        #expect(afterQueued.shouldReload)
    }

    @Test("queued reload clears after replacement terminal")
    func queuedReloadClears() {
        let activeRunID = RunID()
        let activeTerminal = lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate),
            runID: activeRunID,
            trigger: .backgroundSync
        )
        let afterActive = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: activeTerminal)

        let previewTerminal = lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate),
            trigger: .manualCheck,
            intent: .previewFixes
        )
        let afterPreview = advanceQueuedReload(afterActive.next, lifecycle: previewTerminal)

        #expect(afterPreview.next == nil)
        #expect(!afterPreview.shouldReload)

        let directManualTerminal = lifecycle(phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate))
        let afterDirectManual = advanceQueuedReload(afterPreview.next, lifecycle: directManualTerminal)

        #expect(afterDirectManual.next == nil)
        #expect(!afterDirectManual.shouldReload)
    }

    @Test("queued reload tolerates missed active terminal")
    func missedActiveQueues() {
        let activeRunID = RunID()
        let queuedTerminal = lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate),
            trigger: .manualCheck
        )

        let afterQueued = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: queuedTerminal)

        #expect(afterQueued.next == nil)
        #expect(afterQueued.shouldReload)
    }

    @Test("queued reload clears replacement after missed active terminal")
    func missedActiveClears() {
        let activeRunID = RunID()
        let previewTerminal = lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate),
            trigger: .manualCheck,
            intent: .previewFixes
        )

        let afterPreview = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: previewTerminal)

        #expect(afterPreview.next == nil)
        #expect(!afterPreview.shouldReload)
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

private func makeActiveProjection(
    revision: ProjectionRevision,
    lifecycle: RunLifecycleSnapshot
) -> ActivityProjection {
    ActivityProjectionBuilder.makeProjection(from: ActivityProjectionInput(
        tracks: [Core.Track(id: "1", name: "Track 1", artist: "Artist", album: "Album")],
        metrics: nil,
        lastScanDate: Date(timeIntervalSince1970: 1_800_000_000),
        libraryState: .ready,
        processingMode: .preview,
        workflow: .empty,
        pendingVerification: nil,
        runLifecycle: lifecycle,
        isLibrarySyncAvailable: true,
        isAutoSyncRunning: false,
        now: Date(timeIntervalSince1970: 1_800_000_480)
    )).withRevision(revision)
}

private func makeRecoveryProjection(
    revision: ProjectionRevision,
    runID: String = recoveryRunIDString
) -> ActivityProjection {
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
                technicalDetail: runID
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
    var submitRunCallCount = 0
    var reloadCallCount = 0
    var refreshCallCount = 0
    var preflightRunIDs: [RunID] = []
    var queuedReloadBarriers: [RunID] = []

    private var projection: ActivityProjection
    private let preflightOutcome: RecoveryPreflightOutcome?
    private let runResult: RunSubmissionResult
    private let runError: Error?

    init(
        currentRevision: ProjectionRevision = ProjectionRevision(1),
        projection: ActivityProjection? = nil,
        isRunOrchestratorAvailable: Bool = true,
        preflightOutcome: RecoveryPreflightOutcome? = nil,
        runResult: RunSubmissionResult? = nil,
        runError: Error? = nil
    ) {
        self.projection = projection ?? makeRunManuallyProjection(revision: currentRevision, isEnabled: true)
        self.isRunOrchestratorAvailable = isRunOrchestratorAvailable
        self.preflightOutcome = preflightOutcome
        self.runResult = runResult ?? .completedNoOp(lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate)
        ))
        self.runError = runError
    }

    func makeCommands() -> ActivityCommands {
        ActivityCommands(
            isRunOrchestratorAvailable: { self.isRunOrchestratorAvailable },
            submitManualRun: {
                self.submitRunCallCount += 1
                if let runError = self.runError {
                    throw runError
                }
                return self.runResult
            },
            queueManualReload: { runID in
                self.queuedReloadBarriers.append(runID)
            },
            reloadLibrary: { forceRefresh in
                if forceRefresh {
                    self.reloadCallCount += 1
                }
            },
            refreshActivityProjection: {
                self.refreshCallCount += 1
                self.projection = self.projection.withRevision(self.projection.revision.advanced())
                return self.projection
            },
            runRecoveryPreflight: { runID in
                self.preflightRunIDs.append(runID)
                return self.preflightOutcome ?? .inspectable(runID: runID, state: .syncingLibrary)
            },
            currentFixPlanID: {
                "plan-1"
            }
        )
    }
}

private let recoveryRunIDString = "00000000-0000-0000-0000-000000000097"
private let recoveryRunID = RunID(rawValue: UUID(uuidString: recoveryRunIDString) ?? UUID())
private let finishDate = Date(timeIntervalSince1970: 101)

private func lifecycle(
    phase: RunPhase,
    runID: RunID = RunID(),
    trigger: RunTrigger = .manualCheck,
    intent: RunIntent = .observeLibrary
) -> RunLifecycleSnapshot {
    RunLifecycleSnapshot(
        runID: runID,
        requestID: RunRequestID(),
        trigger: trigger,
        intent: intent,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 75,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: trigger.rawValue
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
