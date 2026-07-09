import Core
import Foundation
import Services
import Testing

@Suite("ActivityProjectionLifecycle")
struct ActivityLifecycleTests {
    private let scanDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("syncing library allows manual queueing and marks detect current")
    func syncingAllowsQueue() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .active(.syncingLibrary), trigger: .backgroundSync)
            )
        )

        #expect(projection.title == "Syncing library")
        #expect(projection.subtitle == "Manual sync running · detecting library delta")
        #expect(projection.syncStatusText == "Syncing")
        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .detect) == .current)
        #expect(projection.secondaryCommand?.title == "Queue manual")
        #expect(projection.secondaryCommand?.isEnabled == true)
    }

    @Test("active manual run keeps manual command covered")
    func manualStaysCovered() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .active(.syncingLibrary))
            )
        )

        #expect(projection.secondaryCommand?.title == "Run manually")
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("active run has priority over processing state")
    func activeRunHasPriorityOverProcessingState() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 0,
                    acceptedChangeCount: 0,
                    failedWriteCount: 0,
                    isProcessing: true,
                    phaseLabel: "Processing"
                ),
                runLifecycle: lifecycle(phase: .active(.syncingLibrary))
            )
        )

        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .detect) == .current)
        #expect(projection.status(for: .fix) != .current)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("completed sync does not hide active workflow processing")
    func completedSyncDoesNotHideActiveWorkflowProcessing() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 2,
                    acceptedChangeCount: 0,
                    failedWriteCount: 0,
                    isProcessing: true,
                    phaseLabel: "Writing metadata"
                ),
                runLifecycle: lifecycle(phase: .finished(
                    .completed(SyncResult(newTracks: [editableTrack(id: "new-1")])),
                    finishedAt: now
                ))
            )
        )

        #expect(projection.title == "Writing metadata")
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .diff) == .completed)
        #expect(projection.status(for: .fix) == .current)
    }

    @Test("last sync result with changes marks diff current")
    func lastSyncResultWithChangesMarksDiffCurrent() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .finished(.completed(multiChangeSyncResult()), finishedAt: now))
            )
        )

        #expect(projection.title == "Library ready")
        #expect(projection.subtitle == "7 library changes detected")
        #expect(projection.syncStatusText == "Synced · 7 changes")
        #expect(projection.deltaCount == 7)
        #expect(projection.currentStage == .diff)
        #expect(projection.status(for: .diff) == .current)
        #expect(projection.recentActivity.contains {
            $0.title == "Library sync" && $0.detail == "7 library changes detected"
        })
    }

    @Test("empty library after completed sync keeps empty title")
    func emptyLibraryAfterCompletedSyncKeepsEmptyTitle() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                runLifecycle: lifecycle(phase: .finished(.completedNoOp(SyncResult()), finishedAt: now))
            )
        )

        #expect(projection.title == "Library empty")
        #expect(projection.syncStatusText == "Synced · no changes")
        #expect(projection.subtitle == "No library changes detected")
    }

    @Test("active run takes precedence over a loading library state")
    func activeRunTakesPrecedenceOverLoadingLibraryState() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .loading,
                runLifecycle: lifecycle(phase: .active(.syncingLibrary))
            )
        )

        #expect(projection.title == "Syncing library")
        #expect(projection.subtitle == "Manual sync running · detecting library delta")
        #expect(projection.syncStatusText == "Syncing")
    }

    @Test("failed run takes precedence over an empty library state")
    func failedRunTakesPrecedenceOverEmptyLibraryState() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .empty,
                runLifecycle: lifecycle(phase: .finished(
                    .failed(message: "Music.app is unavailable"),
                    finishedAt: now
                ))
            )
        )

        #expect(projection.title == "Sync needs attention")
    }

    @Test("awaiting review uses diff stage")
    func awaitingReviewUsesDiff() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .active(.awaitingReview))
            )
        )

        #expect(projection.title == "Awaiting review")
        #expect(projection.subtitle == "Review changes before writing")
        #expect(projection.syncStatusText == "Awaiting review")
        #expect(projection.currentStage == .diff)
        #expect(projection.status(for: .diff) == .current)
        #expect(projection.recentActivity.allSatisfy { $0.title != "Library sync failed" })
    }

    @Test("cancelled run is not a sync failure")
    func cancelledRunIsNeutral() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .finished(
                    .cancelled(message: "User cancelled"),
                    finishedAt: now
                ))
            )
        )

        #expect(projection.title == "Run cancelled")
        #expect(projection.subtitle == "User cancelled")
        #expect(projection.syncStatusText == "Cancelled")
        #expect(projection.status(for: .detect) == .current)
        #expect(projection.operationalIssues.isEmpty)
        #expect(projection.recentActivity.contains {
            $0.title == "Run cancelled" && $0.detail == "User cancelled"
        })
        #expect(projection.recentActivity.allSatisfy { $0.title != "Library sync failed" })
    }

    @Test("blocked run is gated without sync failure copy")
    func blockedRunIsGated() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 2,
                    acceptedCount: 0,
                    canApply: true
                ),
                runLifecycle: lifecycle(phase: .suspended(.blocked))
            )
        )
        let issue = try #require(projection.operationalIssues.first)

        #expect(projection.title == "Run blocked")
        #expect(projection.syncStatusText == "Blocked")
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .fix) == .gated)
        #expect(projection.primaryCommand == nil)
        #expect(projection.secondaryCommand?.title == "Check library")
        #expect(projection.secondaryCommand?.variant == .libraryCheck)
        #expect(issue.summary == "Run blocked")
        #expect(issue.category == .safetyBlocked)
        #expect(projection.recentActivity.allSatisfy { $0.title != "Library sync failed" })
    }

    @Test("recoverable run is gated without sync failure copy")
    func recoverableRunIsGated() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 2,
                    acceptedCount: 0,
                    canApply: true
                ),
                runLifecycle: lifecycle(phase: .suspended(.recoverable))
            )
        )
        let issue = try #require(projection.operationalIssues.first)

        #expect(projection.title == "Recovery needed")
        #expect(projection.syncStatusText == "Recovery needed")
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .fix) == .gated)
        #expect(projection.primaryCommand == nil)
        #expect(projection.secondaryCommand?.title == "Check library")
        #expect(projection.secondaryCommand?.variant == .libraryCheck)
        #expect(issue.summary == "Recovery needed")
        #expect(issue.category == .recoveryRequired)
        #expect(projection.recentActivity.allSatisfy { $0.title != "Library sync failed" })
    }

    @Test("last sync result summary delta card mirrors sync changes")
    func lastSyncResultSummaryDeltaCardMirrorsSyncChanges() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .finished(.completed(multiChangeSyncResult()), finishedAt: now))
            )
        )

        let deltaCard = try #require(projection.summaryCards.first { $0.id == "delta" })
        #expect(deltaCard.kind == .delta)
        #expect(deltaCard.value == "7")
        #expect(deltaCard.detail == "library changes")
    }

    @Test("proposed fixes delta card takes precedence over completed sync changes")
    func proposedFixesDeltaCardTakesPrecedenceOverCompletedSyncChanges() throws {
        let workflow = ActivityWorkflowState(
            proposedChangeCount: 3,
            acceptedChangeCount: 0,
            failedWriteCount: 0,
            isProcessing: false,
            phaseLabel: "Review fixes"
        )
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: workflow,
                runLifecycle: lifecycle(phase: .finished(.completed(multiChangeSyncResult()), finishedAt: now))
            )
        )

        let deltaCard = try #require(projection.summaryCards.first { $0.id == "delta" })
        #expect(deltaCard.kind == .delta)
        #expect(deltaCard.value == "3")
        #expect(deltaCard.detail == "candidate fixes")
        #expect(projection.deltaCount == 3)
    }

    @Test("run lifecycle completed no-op projects stable no changes state")
    func runLifecycleCompletedNoOpProjectsStableNoChangesState() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .finished(.completedNoOp(SyncResult()), finishedAt: now))
            )
        )

        #expect(projection.syncStatusText == "Synced · no changes")
        #expect(projection.subtitle == "No library changes detected")
        #expect(projection.primaryCommand == nil)
    }

    @Test("run lifecycle reporting keeps the run active")
    func reportingKeepsActive() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .active(.reporting))
            )
        )

        #expect(projection.syncStatusText == "Syncing")
        #expect(projection.secondaryCommand?.title == "Run manually")
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("run lifecycle failure projects attention state")
    func runLifecycleFailureProjectsAttentionState() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(phase: .finished(
                    .failed(message: "Music.app is unavailable"),
                    finishedAt: now
                ))
            )
        )

        #expect(projection.title == "Sync needs attention")
        #expect(projection.syncStatusText == "Sync failed")
        #expect(projection.status(for: .detect) == .failed)
        #expect(projection.operationalIssues.first?.category == .temporaryUnavailable)
        #expect(projection.operationalIssues.first?.summary == "Library sync failed")
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

    private func multiChangeSyncResult() -> SyncResult {
        SyncResult(
            newTracks: [editableTrack(id: "new-1"), editableTrack(id: "new-2")],
            modifiedTracks: [editableTrack(id: "modified-1")],
            refreshedTracks: [editableTrack(id: "refreshed-1")],
            removedTrackIDs: ["removed-1", "removed-2", "removed-3"]
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

    private func lifecycle(phase: RunPhase, trigger: RunTrigger = .manualCheck) -> RunLifecycleSnapshot {
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
