import Core
import Foundation
import Services
import Testing

@Suite("ActivityBuilder")
struct ActivityBuilderTests {
    private let scanDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("empty activity projection preserves revision and disabled manual command")
    func emptyActivityProjectionPreservesRevisionAndDisabledManualCommand() {
        let projection = ActivityProjection.empty(revision: ProjectionRevision(11))

        #expect(projection.revision == ProjectionRevision(11))
        #expect(projection.title == "Activity")
        #expect(projection.status(for: .watch) == .pending)
        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("ready library exposes run manually command")
    func readyLibraryExposesRunManuallyCommand() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")]
            )
        )

        #expect(projection.revision == .initial)
        #expect(projection.title == "Library ready")
        #expect(projection.subtitle == "Library ready")
        #expect(projection.syncStatusText == "Synced 8m ago")
        #expect(projection.currentStage == .detect)
        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.isEnabled == true)
        #expect(projection.secondaryCommand?.commandKind == .runManually)
    }

    @Test("loading library without a run keeps the scanning title")
    func loadingLibraryWithoutRunKeepsScanningTitle() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .loading
            )
        )

        #expect(projection.title == "Scanning library")
    }

    @Test("failed library state does not mark watch completed")
    func failedLibraryStateDoesNotMarkWatchCompleted() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .failed("Music.app is unavailable")
            )
        )

        #expect(projection.title == "Library needs attention")
        #expect(projection.status(for: .watch) == .failed)
        #expect(projection.status(for: .detect) == .failed)
    }

    @Test("proposed fixes expose review primary command")
    func proposedFixesExposeReviewPrimaryCommand() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 3,
                    acceptedChangeCount: 0,
                    failedWriteCount: 0,
                    isProcessing: false,
                    phaseLabel: "Idle"
                )
            )
        )

        let primaryCommand = try #require(projection.primaryCommand)
        #expect(primaryCommand.id == "review-changes")
        #expect(primaryCommand.title == "Review changes")
        #expect(primaryCommand.style == .primary)
        #expect(primaryCommand.isEnabled)
        #expect(primaryCommand.commandKind == .reviewChanges)
        #expect(projection.secondaryCommand?.commandKind == .runManually)
    }

    @Test("fix plan summary exposes review state without workflow counts")
    func usesFixPlanSummary() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 4,
                    acceptedCount: 3,
                    canApply: true
                )
            )
        )

        let deltaCard = projection.summaryCards.first { $0.id == "delta" }
        let primaryCommand = projection.primaryCommand

        #expect(projection.title == "Fix plan ready")
        #expect(projection.subtitle == "4 candidate fixes · preview mode · no Music tags written")
        #expect(projection.deltaCount == 4)
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .diff) == .completed)
        #expect(projection.status(for: .fix) == .gated)
        #expect(deltaCard?.value == "4")
        #expect(deltaCard?.detail == "candidate fixes")
        #expect(primaryCommand?.commandKind == .reviewChanges)
    }

    @Test("recovery summary takes precedence over fix plan review")
    func recoverySummaryPriority() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 4,
                    acceptedCount: 3,
                    canApply: true
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRunID: "run-1")
            )
        )

        let issue = try #require(projection.operationalIssues.first)

        #expect(projection.title == "Recovery needed")
        #expect(projection.subtitle == "Previous run needs recovery before writes continue")
        #expect(projection.syncStatusText == "Recovery needed")
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .fix) == .gated)
        #expect(projection.primaryCommand?.id == "resume-recovery")
        #expect(projection.primaryCommand?.title == "Resume safely")
        #expect(projection.primaryCommand?.style == .primary)
        #expect(projection.primaryCommand?.isEnabled == true)
        #expect(projection.primaryCommand?.commandKind == .resumeRecovery)
        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.title == "Check library")
        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.variant == .libraryCheck)
        #expect(projection.secondaryCommand?.isEnabled == true)
        #expect(issue.category == .recoveryRequired)
        #expect(issue.summary == "Previous run needs recovery")
    }

    @Test("recovery hold queues library check during active background run")
    func recoveryQueuesCheck() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRunID: "run-1"),
                runLifecycle: lifecycle(phase: .active(.syncingLibrary), trigger: .backgroundSync)
            )
        )

        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.title == "Queue library check")
        #expect(projection.secondaryCommand?.variant == .libraryCheck)
        #expect(projection.secondaryCommand?.isEnabled == true)
        #expect(projection.operationalIssues.first?.category == .recoveryRequired)
    }

    @Test("library blockers take precedence over recovery summary")
    func blocksRecoverySummary() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRunID: "run-1")
            )
        )

        #expect(projection.title == "Library needs attention")
        #expect(projection.subtitle == "Music access denied")
        #expect(projection.syncStatusText == "Synced 8m ago")
        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .fix) == .gated)
        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.title == "Run manually")
        #expect(projection.secondaryCommand?.variant == .standard)
        #expect(projection.operationalIssues.first?.category == .musicPermissionRequired)
        #expect(projection.operationalIssues.first?.summary == "Music permission required")
        #expect(projection.operationalIssues.allSatisfy { $0.category != .recoveryRequired })
    }

    @Test("library blocker suppresses review command during recovery")
    func blocksReviewCommand() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 2,
                    acceptedCount: 0,
                    canApply: true
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRunID: "run-1")
            )
        )

        #expect(projection.primaryCommand == nil)
        #expect(projection.operationalIssues.first?.category == .musicPermissionRequired)
        #expect(projection.operationalIssues.allSatisfy { $0.category != .recoveryRequired })
    }

    @Test("library blocker gates auto-fix status during recovery")
    func gatesAutoFix() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 2,
                    acceptedCount: 0,
                    canApply: true
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRunID: "run-1"),
                processingMode: .autoFix
            )
        )

        #expect(projection.status(for: .fix) == .gated)
    }

    @Test("recovery gates failed writes during library blocker")
    func gatesFailedWrites() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 0,
                    acceptedChangeCount: 0,
                    failedWriteCount: 1,
                    isProcessing: false,
                    phaseLabel: "Idle"
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRunID: "run-1")
            )
        )

        #expect(projection.status(for: .fix) == .gated)
    }

    @Test("summary cards expose semantic kinds instead of UI symbols")
    func summaryCardsExposeSemanticKindsInsteadOfUISymbols() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(tracks: [editableTrack(id: "1")])
        )

        #expect(projection.summaryCards.map(\.kind) == [.automation, .delta, .quality])
    }

    @Test("recent last scan status says synced just now")
    func recentLastScanStatusSaysSyncedJustNow() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: now.addingTimeInterval(-30),
                now: now
            )
        )

        #expect(projection.syncStatusText == "Synced just now")
    }

    @Test("metrics snapshot date backs sync status when explicit scan date is missing")
    func metricsSnapshotDateBacksSyncStatusWhenExplicitScanDateIsMissing() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: nil,
                metrics: ActivityProjectionMetrics(
                    totalTracks: 1,
                    tracksWithGenre: 1,
                    tracksWithYear: 1,
                    tracksWithBoth: 1,
                    protectedFileCount: 0,
                    recentlyAdded: 0,
                    snapshotDate: scanDate
                ),
                usesDefaultScanDate: false
            )
        )

        #expect(projection.syncStatusText == "Synced 8m ago")
        #expect(projection.automationState == .manualScanOnly)
    }

    @Test("projection derives intervention, failed writes, and scan activity from input")
    func projectionDerivesInterventionFailedWritesAndScanActivityFromInput() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1"), editableTrack(id: "2"), editableTrack(id: "3")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 0,
                    acceptedChangeCount: 0,
                    failedWriteCount: 2,
                    isProcessing: false,
                    phaseLabel: "Review"
                ),
                pendingVerification: ActivityPendingVerificationSummary(
                    total: 142,
                    due: 12,
                    problematic: 3,
                    skippedByInterval: 5,
                    verified: 7
                )
            )
        )

        #expect(projection.interventionCount == 142)
        #expect(projection.failedWriteCount == 2)
        #expect(projection.status(for: .fix) == .failed)
        #expect(projection.recentActivity.first?.title == "Library scan")
        #expect(projection.recentActivity.first?.detail == "3 tracks analyzed")
    }

    @Test("library sync unavailable disables run manually command")
    func librarySyncUnavailableDisablesRunManuallyCommand() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                isLibrarySyncAvailable: false
            )
        )

        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    private func makeInput(
        tracks: [Track] = [],
        libraryState: ActivityLibraryState? = nil,
        lastScanDate: Date? = nil,
        metrics: ActivityProjectionMetrics? = nil,
        workflow: ActivityWorkflowState = .empty,
        fixPlan: ActivityFixPlanSummary? = nil,
        recovery: ActivityRecoverySummary? = nil,
        pendingVerification: ActivityPendingVerificationSummary? = nil,
        runLifecycle: RunLifecycleSnapshot? = nil,
        processingMode: ActivityProcessingMode = .preview,
        isLibrarySyncAvailable: Bool = true,
        usesDefaultScanDate: Bool = true,
        now: Date? = nil
    ) -> ActivityProjectionInput {
        ActivityProjectionInput(
            tracks: tracks,
            metrics: metrics,
            lastScanDate: lastScanDate ?? (usesDefaultScanDate ? scanDate : nil),
            libraryState: libraryState ?? (tracks.isEmpty ? .empty : .ready),
            processingMode: processingMode,
            workflow: workflow,
            fixPlan: fixPlan,
            recovery: recovery,
            pendingVerification: pendingVerification,
            runLifecycle: runLifecycle,
            isLibrarySyncAvailable: isLibrarySyncAvailable,
            isAutoSyncRunning: false,
            now: now ?? self.now
        )
    }

    private func editableTrack(id: String) -> Track {
        Track(
            id: id,
            name: "Track \(id)",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 2001,
            trackStatus: "purchased"
        )
    }

    private func lifecycle(phase: RunPhase, trigger: RunTrigger) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: trigger,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: scanDate,
                reason: "manual-check"
            ),
            startedAt: scanDate,
            phase: phase
        )
    }
}
