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
            input: makeInput(run: runFacts(phase: .finished(.completed(SyncResult()), finishedAt: probeDate)))
        )
        let noOp = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .finished(.completedNoOp(SyncResult()), finishedAt: probeDate)))
        )

        #expect(completed.syncStatus.text == "Up to date")
        #expect(noOp.syncStatus.text == "Checked — nothing to do")
        #expect(completed.syncStatus.severity == .nominal)
        #expect(noOp.syncStatus.severity == .nominal)
    }

    @Test("running and writing phases carry their compact lines")
    func activePhasesCarryCompactLines() {
        let running = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .active(.syncingLibrary)))
        )
        let writing = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .active(.writing)))
        )
        let awaitingReview = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .active(.awaitingReview)))
        )

        #expect(running.syncStatus.text == "Running")
        #expect(running.syncStatus.isRunActive == true)
        #expect(writing.syncStatus.text == "Writing")
        #expect(awaitingReview.syncStatus.text == "Awaiting review")
        #expect(awaitingReview.syncStatus.severity == .attention)
    }

    @Test("recovery states read blocked severity")
    func recoveryStatesReadBlocked() {
        let recoverable = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .suspended(.recoverable)))
        )
        let blocked = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .suspended(.blocked)))
        )

        #expect(recoverable.syncStatus.text == "Recovery needed")
        #expect(recoverable.syncStatus.severity == .blocked)
        #expect(blocked.syncStatus.severity == .blocked)
    }

    @Test("a write hold overrides every finished line")
    func holdOverridesFinishedLines() {
        let phases: [RunPhase] = [
            .finished(.completed(SyncResult()), finishedAt: probeDate),
            .finished(.completedNoOp(SyncResult()), finishedAt: probeDate),
            .finished(.cancelled(message: "stopped"), finishedAt: probeDate),
        ]
        for phase in phases {
            let projection = ChromeBuilder.makeProjection(input: makeInput(
                run: runFacts(phase: phase),
                recovery: heldRecovery
            ))
            #expect(projection.syncStatus.text == "Recovery needed")
            #expect(projection.syncStatus.severity == .blocked)
        }
    }

    @Test("a failed run reads attention severity; a plain cancellation stays nominal")
    func failureAndCancellationSeverities() {
        let failed = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .finished(.failed(message: "probe failure"), finishedAt: probeDate)))
        )
        let cancelled = ChromeBuilder.makeProjection(
            input: makeInput(run: runFacts(phase: .finished(.cancelled(message: "stopped"), finishedAt: probeDate)))
        )

        #expect(failed.syncStatus.text == "Sync failed")
        #expect(failed.syncStatus.severity == .attention)
        #expect(cancelled.syncStatus.text == "Cancelled")
        #expect(cancelled.syncStatus.severity == .nominal)
    }

    // MARK: - Recovery hold and command precedence

    @Test("recovery leads the command list under a hold")
    func recoveryOutranksReview() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            recovery: heldRecovery
        ))

        #expect(projection.commands.first?.commandKind == .resumeRecovery)
        #expect(projection.safety.recoveryHold?.blocksWrites == true)
    }

    @Test("the hold carries the recovery run identifier through")
    func holdCarriesRunID() {
        let runID = RunID()
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            recovery: ChromeRecoveryFacts(hasUnresolvedWriteRecovery: true, recoveryRunID: runID)
        ))

        #expect(projection.safety.recoveryHold?.runID == runID)
    }

    @Test("a write hold degrades run-manually to an enabled library check")
    func holdDegradesRunToLibraryCheck() {
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(recovery: heldRecovery)
        )
        let runCommand = projection.commands.first { $0.commandKind == .runManually }

        #expect(runCommand?.isEnabled == true)
        #expect(runCommand?.variant == .libraryCheck)
        #expect(runCommand?.title == "Check library")
    }

    @Test("an unavailable run service disables the command with a reason")
    func unavailableServiceDisablesWithReason() {
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(run: ChromeRunFacts(lifecycle: nil, isRunServiceAvailable: false))
        )
        let runCommand = projection.commands.first { $0.commandKind == .runManually }

        #expect(runCommand?.isEnabled == false)
        #expect(runCommand?.disabledReason?.isEmpty == false)
    }

    @Test("a proven-unavailable Music.app refuses the run command")
    func musicUnavailableRefusesRun() {
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            permissions: ChromePermissions(isMusicAppAvailable: false)
        ))
        let runCommand = projection.commands.first { $0.commandKind == .runManually }

        #expect(runCommand?.isEnabled == false)
        #expect(runCommand?.disabledReason == "Music.app is not available.")
    }

    @Test("an active manual run disables run-manually; a background run can queue")
    func activeRunQueueability() {
        let manual = ChromeBuilder.makeProjection(input: makeInput(
            run: runFacts(phase: .active(.syncingLibrary), trigger: .manualCheck)
        ))
        let background = ChromeBuilder.makeProjection(input: makeInput(
            run: runFacts(phase: .active(.syncingLibrary), trigger: .backgroundSync)
        ))

        #expect(manual.commands.first { $0.commandKind == .runManually }?.isEnabled == false)
        #expect(background.commands.first { $0.commandKind == .runManually }?.isEnabled == true)
    }

    @Test("chrome offers only commands a menu renders")
    func chromeCommandsAreRenderable() {
        // The review-changes descriptor was emitted for years and rendered
        // by no menu — deleted. The in-window Activity surface owns the
        // review affordance; chrome menus offer run and recovery only.
        let projection = ChromeBuilder.makeProjection(input: makeInput())

        #expect(projection.commands.allSatisfy {
            $0.commandKind == .runManually || $0.commandKind == .resumeRecovery
        })
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
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(library: ChromeLibraryFacts(physicalTrackCount: nil, scope: scope))
        )

        #expect(projection.library.effectiveScope?.sourceLabel == "Test artists (2)")
        #expect(projection.library.effectiveScope?.detailLabel == "128 known tracks")
        #expect(projection.library.effectiveScope?.isNarrowedFromPhysical == true)
    }

    @Test("full-library scope is not narrowed")
    func fullLibraryScopeNotNarrowed() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 5000,
            createdAt: probeDate,
            reason: "chrome-test"
        )
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(library: ChromeLibraryFacts(physicalTrackCount: nil, scope: scope))
        )

        #expect(projection.library.effectiveScope?.sourceLabel == "Full library")
        #expect(projection.library.effectiveScope?.isNarrowedFromPhysical == false)
    }

    @Test("without a snapshot chrome never invents a scope")
    func noSnapshotNoScope() {
        let projection = ChromeBuilder.makeProjection(
            input: makeInput(settings: autoFixSettings)
        )

        #expect(projection.library.effectiveScope == nil)
    }

    // MARK: - Processing mode and automation state

    @Test("processing mode uses product language")
    func processingModeUsesProductLanguage() {
        let preview = ChromeBuilder.makeProjection(input: makeInput())
        let autoFix = ChromeBuilder.makeProjection(input: makeInput(settings: autoFixSettings))

        #expect(preview.safety.processingModeLabel == "Preview")
        #expect(autoFix.safety.processingModeLabel == "Auto-fix")
    }

    @Test("automation state priority: running, hold, permission, nothing due, manual")
    func automationStatePriority() {
        let running = ChromeBuilder.makeProjection(input: makeInput(
            run: runFacts(phase: .active(.writing)),
            recovery: heldRecovery
        ))
        let hold = ChromeBuilder.makeProjection(input: makeInput(
            recovery: heldRecovery,
            permissions: ChromePermissions(isMusicAppAvailable: false)
        ))
        let permission = ChromeBuilder.makeProjection(input: makeInput(
            automation: ChromeAutomationFacts(strategy: .manualOnly, isScheduleArmed: false, isIncrementalDue: false),
            permissions: ChromePermissions(isMusicAppAvailable: false)
        ))
        let nothingDue = ChromeBuilder.makeProjection(input: makeInput(
            automation: ChromeAutomationFacts(strategy: .manualOnly, isScheduleArmed: false, isIncrementalDue: false)
        ))
        let manual = ChromeBuilder.makeProjection(input: makeInput())

        #expect(running.safety.automationState == .running)
        #expect(hold.safety.automationState == .recoveryHold)
        #expect(permission.safety.automationState == .permissionRequired)
        #expect(nothingDue.safety.automationState == .nothingDue)
        #expect(manual.safety.automationState == .manualOnly)
    }

    @Test("an armed schedule reads scheduled, not running")
    func armedScheduleReadsScheduled() {
        // Armed is not running (slice 13): the source waits for its next
        // tick; only an active lifecycle reads as running.
        let projection = ChromeBuilder.makeProjection(input: makeInput(
            automation: ChromeAutomationFacts(strategy: .scheduled, isScheduleArmed: true, isIncrementalDue: nil)
        ))

        #expect(projection.safety.automationState == .scheduled)
    }

    @Test("armed beats nothing-due; recovery hold beats armed")
    func armedOrderingInTheTruthTable() {
        let armedNotDue = ChromeBuilder.makeProjection(input: makeInput(
            automation: ChromeAutomationFacts(strategy: .scheduled, isScheduleArmed: true, isIncrementalDue: false)
        ))
        #expect(armedNotDue.safety.automationState == .scheduled)

        let armedHeld = ChromeBuilder.makeProjection(input: makeInput(
            recovery: ChromeRecoveryFacts(hasUnresolvedWriteRecovery: true, recoveryRunID: nil),
            automation: ChromeAutomationFacts(strategy: .scheduled, isScheduleArmed: true, isIncrementalDue: nil)
        ))
        #expect(armedHeld.safety.automationState == .recoveryHold)
    }

    // MARK: - Permissions and issues

    @Test("unprobed permissions pass through unasserted")
    func unprobedPermissionsPassThrough() {
        let projection = ChromeBuilder.makeProjection(input: makeInput())

        #expect(projection.safety.permissions == .unprobed)
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
        let loadFailed = ChromeBuilder.makeProjection(input: makeInput(
            settings: ChromeSettingsFacts(isPreviewMode: true, saveErrorMessage: nil, hasLoadFailed: true)
        ))
        let saveFailed = ChromeBuilder.makeProjection(input: makeInput(
            settings: ChromeSettingsFacts(isPreviewMode: true, saveErrorMessage: "disk full", hasLoadFailed: false)
        ))

        #expect(loadFailed.operationalIssues.contains { $0.category == .configurationRequired })
        let saveIssue = saveFailed.operationalIssues.first { $0.category == .temporaryUnavailable }
        #expect(saveIssue?.technicalDetail == "disk full")
    }
}

private let probeDate = Date(timeIntervalSince1970: 1_800_000_000)

private let heldRecovery = ChromeRecoveryFacts(hasUnresolvedWriteRecovery: true, recoveryRunID: RunID())

private let autoFixSettings = ChromeSettingsFacts(
    isPreviewMode: false,
    saveErrorMessage: nil,
    hasLoadFailed: false
)

private func makeInput(
    run: ChromeRunFacts = ChromeRunFacts(lifecycle: nil, isRunServiceAvailable: true),
    recovery: ChromeRecoveryFacts = ChromeRecoveryFacts(hasUnresolvedWriteRecovery: false, recoveryRunID: nil),
    settings: ChromeSettingsFacts = ChromeSettingsFacts(
        isPreviewMode: true,
        saveErrorMessage: nil,
        hasLoadFailed: false
    ),
    automation: ChromeAutomationFacts = ChromeAutomationFacts(strategy: .manualOnly, isScheduleArmed: false, isIncrementalDue: nil),
    library: ChromeLibraryFacts = ChromeLibraryFacts(physicalTrackCount: nil, scope: nil),
    permissions: ChromePermissions = .unprobed
) -> ChromeInput {
    ChromeInput(
        run: run,
        recovery: recovery,
        settings: settings,
        automation: automation,
        library: library,
        permissions: permissions
    )
}

private func runFacts(
    phase: RunPhase,
    trigger: RunTrigger = .manualCheck
) -> ChromeRunFacts {
    ChromeRunFacts(
        lifecycle: RunLifecycleSnapshot(
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
        ),
        isRunServiceAvailable: true
    )
}
