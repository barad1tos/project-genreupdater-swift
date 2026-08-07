import Core
import Foundation
import Testing
@testable import Services

@Suite("Chrome builder truth tables")
struct ChromeBuilderTests {
    // MARK: - Sync severity

    @Test("no lifecycle and no hold reads Idle at nominal severity")
    func idleWithoutLifecycle() {
        let projection = ChromeBuilder.makeProjection(input: makeInput())

        #expect(projection.syncStatus.text == "Idle")
        #expect(projection.syncStatus.severity == .nominal)
        #expect(projection.syncStatus.isRunActive == false)
    }

    @Test("a no-op completion is distinct from an effective one")
    func noOpCompletionIsDistinct() {
        let completed = ChromeBuilder.makeProjection(
            input: makeInput(lifecycle: makeLifecycle(phase: .finished(
                .completed(SyncResult()),
                finishedAt: probeDate
            )))
        )
        let noOp = ChromeBuilder.makeProjection(
            input: makeInput(lifecycle: makeLifecycle(phase: .finished(
                .completedNoOp(SyncResult()),
                finishedAt: probeDate
            )))
        )

        #expect(completed.syncStatus.text == "Up to date")
        #expect(noOp.syncStatus.text == "Checked — nothing to do")
        #expect(completed.syncStatus.severity == .nominal)
        #expect(noOp.syncStatus.severity == .nominal)
    }

    @Test("recovery states read blocked severity")
    func recoveryStatesReadBlocked() {
        let recoverable = ChromeBuilder.makeProjection(
            input: makeInput(lifecycle: makeLifecycle(phase: .suspended(.recoverable)))
        )
        let blocked = ChromeBuilder.makeProjection(
            input: makeInput(lifecycle: makeLifecycle(phase: .suspended(.blocked)))
        )

        #expect(recoverable.syncStatus.text == "Recovery needed")
        #expect(recoverable.syncStatus.severity == .blocked)
        #expect(blocked.syncStatus.severity == .blocked)
    }

    @Test("a write hold overrides a finished run's nominal line")
    func holdOverridesFinishedLine() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            lifecycle: makeLifecycle(phase: .finished(.completed(SyncResult()), finishedAt: probeDate)),
            hasUnresolvedWriteRecovery: true
        ))

        #expect(projection.syncStatus.text == "Recovery needed")
        #expect(projection.syncStatus.severity == .blocked)
    }

    @Test("a failed run reads attention severity")
    func failureReadsAttention() {
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(lifecycle: makeLifecycle(phase: .finished(
                .failed(message: "probe failure"),
                finishedAt: probeDate
            )))
        )

        #expect(projection.syncStatus.text == "Sync failed")
        #expect(projection.syncStatus.severity == .attention)
    }

    // MARK: - Recovery hold and command precedence

    @Test("recovery outranks a reviewable fix plan as the first command")
    func recoveryOutranksReview() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            hasUnresolvedWriteRecovery: true,
            hasReviewableFixPlan: true
        ))

        #expect(projection.commands.first?.commandKind == .resumeRecovery)
        #expect(projection.recoveryHold?.blocksWrites == true)
        #expect(!projection.commands.contains { $0.commandKind == .reviewChanges })
    }

    @Test("a write hold degrades run-manually to an enabled library check")
    func holdDegradesRunToLibraryCheck() {
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(hasUnresolvedWriteRecovery: true)
        )
        let runCommand = projection.commands.first { $0.commandKind == .runManually }

        #expect(runCommand?.isEnabled == true)
        #expect(runCommand?.variant == .libraryCheck)
        #expect(runCommand?.title == "Check library")
    }

    @Test("an unavailable run service disables the command with a reason")
    func unavailableServiceDisablesWithReason() {
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(isRunServiceAvailable: false)
        )
        let runCommand = projection.commands.first { $0.commandKind == .runManually }

        #expect(runCommand?.isEnabled == false)
        #expect(runCommand?.disabledReason?.isEmpty == false)
    }

    @Test("an active manual run disables run-manually; a background run can queue")
    func activeRunQueueability() {
        let manual = ChromeBuilder.makeProjection(input: makeInput(
            lifecycle: makeLifecycle(phase: .active(.syncingLibrary), trigger: .manualCheck)
        ))
        let background = ChromeBuilder.makeProjection(input: makeInput(
            lifecycle: makeLifecycle(phase: .active(.syncingLibrary), trigger: .backgroundSync)
        ))

        #expect(manual.commands.first { $0.commandKind == .runManually }?.isEnabled == false)
        #expect(background.commands.first { $0.commandKind == .runManually }?.isEnabled == true)
    }

    @Test("a reviewable plan without a hold offers review changes")
    func reviewablePlanOffersReview() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(hasReviewableFixPlan: true))

        #expect(projection.commands.contains { $0.commandKind == .reviewChanges })
    }

    // MARK: - Scope

    @Test("test-artists scope is narrowed and labeled from the snapshot")
    func artistsScopeNarrowed() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Clutch", "Mastodon"],
            knownTrackCount: 128,
            createdAt: probeDate,
            reason: "chrome-test"
        )
        let projection = ChromeBuilder.makeProjection(input: makeInput(scope: scope))

        #expect(projection.effectiveScope?.sourceLabel == "Test artists (2)")
        #expect(projection.effectiveScope?.detailLabel == "128 known tracks")
        #expect(projection.effectiveScope?.isNarrowedFromPhysical == true)
    }

    @Test("full-library scope is not narrowed")
    func fullLibraryScopeNotNarrowed() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 5000,
            createdAt: probeDate,
            reason: "chrome-test"
        )
        let projection = ChromeBuilder.makeProjection(input: makeInput(scope: scope))

        #expect(projection.effectiveScope?.sourceLabel == "Full library")
        #expect(projection.effectiveScope?.isNarrowedFromPhysical == false)
    }

    @Test("without a snapshot chrome never invents a scope")
    func noSnapshotNoScope() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(isPreviewMode: false))

        #expect(projection.effectiveScope == nil)
    }

    // MARK: - Processing mode and automation state

    @Test("processing mode uses product language")
    func processingModeUsesProductLanguage() {
        let preview = ChromeBuilder.makeProjection(input: makeInput(isPreviewMode: true))
        let autoFix = ChromeBuilder.makeProjection(input: makeInput(isPreviewMode: false))

        #expect(preview.processingModeLabel == "Preview")
        #expect(autoFix.processingModeLabel == "Auto-fix")
    }

    @Test("automation state priority: running, hold, permission, nothing due, manual")
    func automationStatePriority() {
        let running = ChromeBuilder.makeProjection(input: makeInput(
            lifecycle: makeLifecycle(phase: .active(.writing)),
            hasUnresolvedWriteRecovery: true
        ))
        let hold = ChromeBuilder.makeProjection(input: makeInput(
            hasUnresolvedWriteRecovery: true,
            permissions: ChromePermissions(isMusicAppAvailable: false)
        ))
        let permission = ChromeBuilder.makeProjection(input: makeInput(
            isIncrementalDue: false,
            permissions: ChromePermissions(isMusicAppAvailable: false)
        ))
        let nothingDue = ChromeBuilder.makeProjection(input: makeInput(isIncrementalDue: false))
        let manual = ChromeBuilder.makeProjection(input: makeInput())

        #expect(running.automationState == .running)
        #expect(hold.automationState == .recoveryHold)
        #expect(permission.automationState == .permissionRequired)
        #expect(nothingDue.automationState == .nothingDue)
        #expect(manual.automationState == .manualOnly)
    }

    // MARK: - Permissions and issues

    @Test("unprobed permissions pass through unasserted")
    func unprobedPermissionsPassThrough() {
        let projection = ChromeBuilder.makeProjection(input: makeInput())

        #expect(projection.permissions == .unprobed)
        #expect(projection.operationalIssues.isEmpty)
    }

    @Test("a denied probe becomes a typed issue with a next action")
    func deniedProbeBecomesTypedIssue() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            permissions: ChromePermissions(isMusicAppAvailable: false)
        ))

        let issue = projection.operationalIssues.first { $0.category == .musicUnavailable }
        #expect(issue != nil)
        #expect(issue?.nextAction?.isEmpty == false)
    }

    @Test("settings persistence failures surface as configuration issues")
    func settingsFailuresSurface() {
        let loadFailed = ChromeBuilder.makeProjection(input: makeInput(settingsLoadFailed: true))
        let saveFailed = ChromeBuilder.makeProjection(
            input: makeInput(settingsSaveErrorMessage: "disk full")
        )

        #expect(loadFailed.operationalIssues.contains { $0.category == .configurationRequired })
        let saveIssue = saveFailed.operationalIssues.first { $0.category == .temporaryUnavailable }
        #expect(saveIssue?.technicalDetail == "disk full")
    }
}

private let probeDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makeInput(
    lifecycle: RunLifecycleSnapshot? = nil,
    hasUnresolvedWriteRecovery: Bool = false,
    isPreviewMode: Bool = true,
    isIncrementalDue: Bool? = nil,
    scope: ProcessingScopeSnapshot? = nil,
    permissions: ChromePermissions = .unprobed,
    settingsSaveErrorMessage: String? = nil,
    settingsLoadFailed: Bool = false,
    isRunServiceAvailable: Bool = true,
    hasReviewableFixPlan: Bool = false
) -> ChromeInput {
    ChromeInput(
        lifecycle: lifecycle,
        hasUnresolvedWriteRecovery: hasUnresolvedWriteRecovery,
        recoveryRunID: hasUnresolvedWriteRecovery ? RunID() : nil,
        isPreviewMode: isPreviewMode,
        isAutoSyncRunning: false,
        isIncrementalDue: isIncrementalDue,
        physicalTrackCount: nil,
        scope: scope,
        permissions: permissions,
        settingsSaveErrorMessage: settingsSaveErrorMessage,
        settingsLoadFailed: settingsLoadFailed,
        isRunServiceAvailable: isRunServiceAvailable,
        hasReviewableFixPlan: hasReviewableFixPlan
    )
}

private func makeLifecycle(
    phase: RunPhase,
    trigger: RunTrigger = .manualCheck
) -> RunLifecycleSnapshot {
    RunLifecycleSnapshot(
        runID: RunID(),
        requestID: RunRequestID(),
        trigger: trigger,
        intent: .observeLibrary,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: probeDate,
            reason: "chrome-lifecycle-test"
        ),
        startedAt: probeDate,
        phase: phase
    )
}
