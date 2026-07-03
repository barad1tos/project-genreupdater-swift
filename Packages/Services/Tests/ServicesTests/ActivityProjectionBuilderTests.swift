import Core
import Foundation
import Services
import Testing

@Suite("ActivityProjectionBuilder")
struct ActivityProjectionBuilderTests {
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
        let projection = ActivityProjectionBuilder.makeProjection(
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

    @Test("syncing library disables run manually and marks detect current")
    func syncingLibraryDisablesRunManuallyAndMarksDetectCurrent() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(state: .syncingLibrary)
            )
        )

        #expect(projection.title == "Syncing library")
        #expect(projection.subtitle == "Manual sync running · detecting library delta")
        #expect(projection.syncStatusText == "Syncing")
        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .detect) == .current)
        #expect(projection.secondaryCommand?.title == "Syncing")
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("active run has priority over processing state")
    func activeRunHasPriorityOverProcessingState() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 0,
                    acceptedChangeCount: 0,
                    failedWriteCount: 0,
                    isProcessing: true,
                    phaseLabel: "Processing"
                ),
                runLifecycle: lifecycle(state: .syncingLibrary)
            )
        )

        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .detect) == .current)
        #expect(projection.status(for: .fix) != .current)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("completed sync does not hide active workflow processing")
    func completedSyncDoesNotHideActiveWorkflowProcessing() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 2,
                    acceptedChangeCount: 0,
                    failedWriteCount: 0,
                    isProcessing: true,
                    phaseLabel: "Writing metadata"
                ),
                runLifecycle: lifecycle(
                    state: .completed,
                    syncResult: SyncResult(newTracks: [editableTrack(id: "new-1")])
                )
            )
        )

        #expect(projection.title == "Writing metadata")
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .diff) == .completed)
        #expect(projection.status(for: .fix) == .current)
    }

    @Test("last sync result with changes marks diff current")
    func lastSyncResultWithChangesMarksDiffCurrent() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(state: .completed, syncResult: multiChangeSyncResult())
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
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                runLifecycle: lifecycle(state: .completedNoOp, syncResult: SyncResult())
            )
        )

        #expect(projection.title == "Library empty")
        #expect(projection.syncStatusText == "Synced · no changes")
        #expect(projection.subtitle == "No library changes detected")
    }

    @Test("failed library state does not mark watch completed")
    func failedLibraryStateDoesNotMarkWatchCompleted() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .failed("Music.app is unavailable")
            )
        )

        #expect(projection.title == "Library needs attention")
        #expect(projection.status(for: .watch) == .failed)
        #expect(projection.status(for: .detect) == .failed)
    }

    @Test("last sync result summary delta card mirrors sync changes")
    func lastSyncResultSummaryDeltaCardMirrorsSyncChanges() throws {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(state: .completed, syncResult: multiChangeSyncResult())
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
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: workflow,
                runLifecycle: lifecycle(state: .completed, syncResult: multiChangeSyncResult())
            )
        )

        let deltaCard = try #require(projection.summaryCards.first { $0.id == "delta" })
        #expect(deltaCard.kind == .delta)
        #expect(deltaCard.value == "3")
        #expect(deltaCard.detail == "candidate fixes")
        #expect(projection.deltaCount == 3)
    }

    @Test("proposed fixes expose review primary command")
    func proposedFixesExposeReviewPrimaryCommand() throws {
        let projection = ActivityProjectionBuilder.makeProjection(
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

    @Test("summary cards expose semantic kinds instead of UI symbols")
    func summaryCardsExposeSemanticKindsInsteadOfUISymbols() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(tracks: [editableTrack(id: "1")])
        )

        #expect(projection.summaryCards.map(\.kind) == [.automation, .delta, .quality])
    }

    @Test("recent last scan status says synced just now")
    func recentLastScanStatusSaysSyncedJustNow() {
        let projection = ActivityProjectionBuilder.makeProjection(
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
        let projection = ActivityProjectionBuilder.makeProjection(
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
        let projection = ActivityProjectionBuilder.makeProjection(
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
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                isLibrarySyncAvailable: false
            )
        )

        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("run lifecycle completed no-op projects stable no changes state")
    func runLifecycleCompletedNoOpProjectsStableNoChangesState() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(
                    state: .completedNoOp,
                    syncResult: SyncResult()
                )
            )
        )

        #expect(projection.syncStatusText == "Synced · no changes")
        #expect(projection.subtitle == "No library changes detected")
        #expect(projection.primaryCommand == nil)
    }

    @Test("run lifecycle failure projects attention state")
    func runLifecycleFailureProjectsAttentionState() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(
                    state: .failed,
                    failureMessage: "Music.app is unavailable"
                )
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
        pendingVerification: ActivityPendingVerificationSummary? = nil,
        runLifecycle: RunLifecycleSnapshot? = nil,
        isLibrarySyncAvailable: Bool = true,
        usesDefaultScanDate: Bool = true,
        now: Date? = nil
    ) -> ActivityProjectionInput {
        ActivityProjectionInput(
            tracks: tracks,
            metrics: metrics,
            lastScanDate: lastScanDate ?? (usesDefaultScanDate ? scanDate : nil),
            libraryState: libraryState ?? (tracks.isEmpty ? .empty : .ready),
            processingMode: .preview,
            workflow: workflow,
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

    private func lifecycle(
        state: RunLifecycleState,
        syncResult: SyncResult? = nil,
        failureMessage: String? = nil
    ) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            state: state,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: scanDate,
                reason: "manual-check"
            ),
            syncResult: syncResult,
            failureMessage: failureMessage,
            startedAt: scanDate,
            finishedAt: state == .created || state == .syncingLibrary ? nil : now
        )
    }
}
