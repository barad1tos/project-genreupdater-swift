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
        let harness = ActivityFixtures.Harness(projection: makeReviewProjection(revision: ProjectionRevision(2)))
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
        let harness = ActivityFixtures.Harness(currentRevision: ProjectionRevision(2))
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
        let harness = ActivityFixtures.Harness(currentRevision: ProjectionRevision(2))
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
        let activeRun = ActivityFixtures.lifecycle(phase: .active(.syncingLibrary))
        let harness = ActivityFixtures.Harness(runResult: .alreadyCovered(activeRun: activeRun))
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
        let active = ActivityFixtures.lifecycle(phase: .active(.syncingLibrary))
        let harness = ActivityFixtures.Harness(runResult: .queued(activeRun: active))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .queued)
        #expect(result.message == "Manual check queued after current run.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.queuedReloadBarriers == [active.runID])
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("cancelled manual run returns no-op result")
    func manualRunReturnsCancelledNoOp() async {
        let cancelled = ActivityFixtures.lifecycle(
            phase: .finished(.cancelled(message: "Run cancelled"), finishedAt: ActivityFixtures.finishDate)
        )
        let harness = ActivityFixtures.Harness(runResult: .cancelled(cancelled))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "Manual check cancelled.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 2)
    }

    @Test("active background projection queues manual run")
    func backgroundQueuesManual() async {
        let active = ActivityFixtures.lifecycle(phase: .active(.syncingLibrary), trigger: .backgroundSync)
        let harness = ActivityFixtures.Harness(
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
        let harness = ActivityFixtures.Harness(isRunOrchestratorAvailable: false)
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
        let harness = ActivityFixtures.Harness(projection: ActivityFixtures.makeManualProjection(
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

    @Test("run manually rejects missing secondary command")
    func rejectsMissingSecondary() async {
        let harness = ActivityFixtures.Harness(projection: makeReviewProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Manual check is no longer available.")
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
    }

    @Test("disabled library check rejects with recovery wording")
    func rejectsDisabledCheck() async {
        let harness = ActivityFixtures.Harness(projection: ActivityFixtures.makeRecoveryProjection(
            revision: ProjectionRevision(2),
            isSecondaryEnabled: false
        ))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Library check is no longer available.")
        #expect((harness.submitRunCallCount, harness.reloadCallCount, harness.refreshCallCount) == (0, 0, 1))
    }

    @Test("review changes returns blocked by recovery for recovery hold")
    func reviewChangesReturnsBlockedByRecoveryForRecoveryHold() async {
        let harness = ActivityFixtures.Harness(projection: ActivityFixtures
            .makeRecoveryProjection(revision: ProjectionRevision(2)))
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
        let harness = ActivityFixtures.Harness(projection: ActivityFixtures
            .makeRecoveryProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .navigated)
        #expect(result.message == "Opening recovery.")
        #expect(result.navigationTarget == .recovery(runID: ActivityFixtures.recoveryRunIDString))
        #expect(harness.preflightRunIDs == [ActivityFixtures.recoveryRunID])
        #expect(harness.submitRunCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("resume recovery resolves when preflight finds terminal record")
    func resolvedRecoveryNoOps() async {
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .resolved(runID: ActivityFixtures.recoveryRunID, reason: .alreadyFinished)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .noOp)
        #expect(result.message == "Recovery is no longer required.")
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs == [ActivityFixtures.recoveryRunID])
        #expect(harness.refreshCallCount == 1)
    }

    @Test("resume recovery surfaces write-adjacent preflight attention")
    func writeAdjacentReview() async {
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .needsAttention(
                runID: ActivityFixtures.recoveryRunID,
                reason: .writeAdjacentState(.reporting)
            )
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Recovery needs review.")
        #expect(result.issue?.id == "recovery-needs-attention")
        #expect(result.issue?.category == .safetyBlocked)
        #expect(result.issue?.technicalDetail == "reporting")
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs == [ActivityFixtures.recoveryRunID])
    }

    @Test("resume restored recovery navigates to verification")
    func restoredRecoveryNavigates() async {
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .needsAttention(
                runID: ActivityFixtures.recoveryRunID,
                reason: .unresolvedState(.recoverable)
            )
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .navigated)
        #expect(result.navigationTarget == .recovery(runID: ActivityFixtures.recoveryRunIDString))
        #expect(harness.preflightRunIDs == [ActivityFixtures.recoveryRunID])
    }

    @Test("resume recovery surfaces blocked preflight")
    func blockedNeedsAttention() async {
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            preflightOutcome: .blocked(runID: ActivityFixtures.recoveryRunID, reason: .storeUnavailable)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.resumeRecovery())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Recovery preflight is unavailable.")
        #expect(result.issue?.id == "recovery-preflight-blocked")
        #expect(result.issue?.category == .temporaryUnavailable)
        #expect(result.navigationTarget == nil)
        #expect(harness.preflightRunIDs == [ActivityFixtures.recoveryRunID])
    }

    @Test("resume recovery rejects malformed run id before preflight")
    func invalidIDBlocks() async {
        let harness = ActivityFixtures.Harness(projection: ActivityFixtures.makeRecoveryProjection(
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
        let command = ActivityCommands.command(for: ActivityFixtures.makeRecoveryProjection(
            revision: ProjectionRevision(2)
        ).primaryCommand)

        #expect(command?.kind == .resumeRecovery)
    }

    @Test("resume recovery reports library blocker")
    func recoveryReportsBlocker() async {
        let harness = ActivityFixtures.Harness(projection: blockedRecoveryProjection(revision: ProjectionRevision(2)))
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

    @Test("run manually behaves as library check during recovery hold")
    func checksLibraryDuringRecovery() async {
        let harness = ActivityFixtures.Harness(projection: ActivityFixtures
            .makeRecoveryProjection(revision: ProjectionRevision(2)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected · writes remain held.")
        #expect((harness.submitRunCallCount, harness.reloadCallCount, harness.refreshCallCount) == (1, 1, 2))
    }

    @Test("run manually uses builder variant during recovery hold")
    func usesBuilderVariant() async {
        let projection = ActivityBuilder.makeProjection(from: ActivityProjectionInput(
            tracks: [track(id: "1")],
            metrics: nil,
            lastScanDate: Date(timeIntervalSince1970: 1_800_000_000),
            libraryState: .ready,
            processingMode: .preview,
            workflow: .empty,
            recovery: ActivityRecoverySummary(
                unresolvedRunCount: 1,
                latestRecoveryRunID: ActivityFixtures.recoveryRunIDString
            ),
            pendingVerification: nil,
            isLibrarySyncAvailable: true,
            isAutoSyncRunning: false,
            now: Date(timeIntervalSince1970: 1_800_000_480)
        ))
        let harness = ActivityFixtures.Harness(projection: projection)
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.message == "No library changes detected · writes remain held.")
        #expect(harness.submitRunCallCount == 1)
    }

    @Test("library check reports recovery-held changes")
    func reportsHeldChanges() async {
        let syncResult = SyncResult(
            newTracks: [track(id: "NEW")],
            modifiedTracks: [track(id: "MODIFIED")]
        )
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            runResult: .completed(ActivityFixtures.lifecycle(phase: .finished(
                .completed(syncResult),
                finishedAt: ActivityFixtures.finishDate
            )))
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .accepted)
        #expect(result.message == "Library check found 2 changes · writes remain held.")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 1)
    }

    @Test("library check failure uses recovery wording")
    func usesRecoveryFailureCopy() async {
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            runError: TestError(errorDescription: "Run orchestrator crashed")
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Library check failed.")
        #expect(result.issue?.id == "library-check-failed")
        #expect(result.issue?.summary == "Library check failed")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
    }

    @Test("failed library check result uses recovery wording")
    func surfacesCheckFailure() async {
        let harness = ActivityFixtures.Harness(
            projection: ActivityFixtures.makeRecoveryProjection(revision: ProjectionRevision(2)),
            runResult: .failed(ActivityFixtures.lifecycle(phase: .finished(
                .failed(message: "Music.app is unavailable"),
                finishedAt: ActivityFixtures.finishDate
            )))
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Library check failed.")
        #expect(result.issue?.id == "library-check-failed")
        #expect(result.issue?.category == .temporaryUnavailable)
        #expect(result.issue?.summary == "Library check failed")
        #expect(result.issue?.technicalDetail == "Music.app is unavailable")
        #expect(harness.submitRunCallCount == 1)
        #expect(harness.reloadCallCount == 0)
    }

    @Test("completed no-op run reloads library and returns no-op")
    func completedNoOpRunReloadsLibraryAndReturnsNoOp() async {
        let harness = ActivityFixtures.Harness(runResult: .completedNoOp(ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate)
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
        let harness = ActivityFixtures.Harness(
            runResult: .completed(ActivityFixtures.lifecycle(phase: .finished(
                .completed(syncResult),
                finishedAt: ActivityFixtures.finishDate
            )))
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
        let harness = ActivityFixtures.Harness(runResult: .failed(ActivityFixtures.lifecycle(phase: .finished(
            .failed(message: "Music.app is unavailable"),
            finishedAt: ActivityFixtures.finishDate
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

    @Test("recoverable run preserves its reason")
    func recoverableRunKeepsReason() async {
        let reason = "Music.app write outcome is unknown"
        let harness = ActivityFixtures.Harness(runResult: .recoverable(
            ActivityFixtures.lifecycle(phase: .suspended(.recoverable)),
            reason: reason
        ))

        let result = await harness.makeCommands().handle(.runManually())

        #expect(result.status == .blockedByRecovery)
        #expect(result.issue?.id == "run-recovery-required")
        #expect(result.issue?.category == .recoveryRequired)
        #expect(result.issue?.technicalDetail == reason)
        #expect(harness.reloadCallCount == 0)
    }

    @Test("submit error returns requires attention")
    func submitErrorReturnsRequiresAttention() async {
        let harness = ActivityFixtures.Harness(runError: TestError(errorDescription: "Run orchestrator crashed"))
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
        let activeTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            runID: activeRunID,
            trigger: .backgroundSync
        )

        let afterActive = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: activeTerminal)

        #expect(afterActive.next == .waitingForQueued)
        #expect(!afterActive.shouldReload)

        let queuedTerminal = ActivityFixtures.lifecycle(phase: .finished(
            .completedNoOp(SyncResult()),
            finishedAt: ActivityFixtures.finishDate
        ))
        let afterQueued = advanceQueuedReload(afterActive.next, lifecycle: queuedTerminal)

        #expect(afterQueued.next == nil)
        #expect(afterQueued.shouldReload)
    }

    @Test("queued reload clears after replacement terminal")
    func queuedReloadClears() {
        let activeRunID = RunID()
        let activeTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            runID: activeRunID,
            trigger: .backgroundSync
        )
        let afterActive = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: activeTerminal)

        let previewTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            trigger: .manualCheck,
            intent: .previewFixes
        )
        let afterPreview = advanceQueuedReload(afterActive.next, lifecycle: previewTerminal)

        #expect(afterPreview.next == nil)
        #expect(!afterPreview.shouldReload)

        let directManualTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate)
        )
        let afterDirectManual = advanceQueuedReload(afterPreview.next, lifecycle: directManualTerminal)

        #expect(afterDirectManual.next == nil)
        #expect(!afterDirectManual.shouldReload)
    }

    @Test("queued reload tolerates missed active terminal")
    func missedActiveQueues() {
        let activeRunID = RunID()
        let queuedTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            trigger: .manualCheck
        )

        let afterQueued = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: queuedTerminal)

        #expect(afterQueued.next == nil)
        #expect(afterQueued.shouldReload)
    }

    @Test("queued reload clears replacement after missed active terminal")
    func missedActiveClears() {
        let activeRunID = RunID()
        let previewTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
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

private func makeActiveProjection(
    revision: ProjectionRevision,
    lifecycle: RunLifecycleSnapshot
) -> ActivityProjection {
    ActivityBuilder.makeProjection(from: ActivityProjectionInput(
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
            )
        ]
    )
}

private struct TestError: LocalizedError {
    let errorDescription: String?
}
