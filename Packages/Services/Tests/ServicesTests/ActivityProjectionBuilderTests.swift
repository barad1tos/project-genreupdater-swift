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
                syncState: .running
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

    @Test("sync state has priority over processing state")
    func syncStateHasPriorityOverProcessingState() {
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
                syncState: .running
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
                syncState: .completed(ActivitySyncSummary(
                    new: 1,
                    modified: 0,
                    identityChanged: 0,
                    refreshed: 0,
                    removed: 0
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
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                syncState: .completed(ActivitySyncSummary(
                    new: 2,
                    modified: 1,
                    identityChanged: 0,
                    refreshed: 1,
                    removed: 3
                ))
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

    @Test("completed sync without changes uses stable no changes status")
    func completedSyncWithoutChangesUsesStableNoChangesStatus() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                syncState: .completed(ActivitySyncSummary(
                    new: 0,
                    modified: 0,
                    identityChanged: 0,
                    refreshed: 0,
                    removed: 0
                ))
            )
        )

        #expect(projection.syncStatusText == "Synced · no changes")
        #expect(projection.subtitle == "No library changes detected")
    }

    @Test("empty library after completed sync keeps empty title")
    func emptyLibraryAfterCompletedSyncKeepsEmptyTitle() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                syncState: .completed(ActivitySyncSummary(
                    new: 0,
                    modified: 0,
                    identityChanged: 0,
                    refreshed: 0,
                    removed: 0
                ))
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
                syncState: .completed(ActivitySyncSummary(
                    new: 2,
                    modified: 1,
                    identityChanged: 0,
                    refreshed: 1,
                    removed: 3
                ))
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
                syncState: .completed(ActivitySyncSummary(
                    new: 2,
                    modified: 1,
                    identityChanged: 0,
                    refreshed: 1,
                    removed: 3
                ))
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

    @Test("sync failure exposes operational issue and failed detect stage")
    func syncFailureExposesOperationalIssueAndFailedDetectStage() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                syncState: .failed("Music.app is unavailable")
            )
        )

        #expect(projection.title == "Sync needs attention")
        #expect(projection.syncStatusText == "Sync failed")
        #expect(projection.status(for: .detect) == .failed)
        #expect(projection.operationalIssues.first?.category == .temporaryUnavailable)
        #expect(projection.operationalIssues.first?.summary == "Library sync failed")
    }

    @Test("run lifecycle syncing overrides legacy sync state")
    func runLifecycleSyncingOverridesLegacySyncState() {
        let projection = ActivityProjectionBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                runLifecycle: lifecycle(state: .syncingLibrary),
                syncState: .completed(ActivitySyncSummary(
                    new: 2,
                    modified: 0,
                    identityChanged: 0,
                    refreshed: 0,
                    removed: 0
                ))
            )
        )

        #expect(projection.title == "Syncing library")
        #expect(projection.syncStatusText == "Syncing")
        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .detect) == .current)
        #expect(projection.secondaryCommand?.title == "Syncing")
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
        runLifecycle: RunLifecycleSnapshot? = nil,
        syncState: ActivitySyncState = .idle,
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
            pendingVerification: nil,
            runLifecycle: runLifecycle,
            syncState: syncState,
            isLibrarySyncAvailable: true,
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
