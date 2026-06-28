import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("DesignActivitySnapshotAdapter")
struct DesignActivitySnapshotAdapterTests {
    private let scanDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("maps cached metrics without live tracks")
    func mapsCachedMetricsWithoutLiveTracks() {
        let metrics = PersistedMetricsSnapshot(
            totalTracks: 10,
            tracksWithGenre: 7,
            tracksWithYear: 8,
            tracksWithBoth: 6,
            tracksNeedingGenre: 3,
            tracksNeedingYear: 2,
            protectedFileCount: 1,
            recentlyAdded: 4,
            timestamp: scanDate,
            previousTotalTracks: 9,
            previousTracksNeedingGenre: 5,
            previousTracksNeedingYear: 1
        )
        let workflow = WorkflowDashboardState(
            proposedChangeCount: 7,
            acceptedChangeCount: 5,
            failedWriteCount: 0,
            isProcessing: false,
            phaseLabel: "Review"
        )

        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(metricsSnapshot: metrics, workflow: workflow)
        )

        #expect(snapshot.health.totalTracks == 10)
        #expect(snapshot.health.missingGenre == 3)
        #expect(snapshot.health.missingYear == 2)
        #expect(snapshot.health.completeMetadata == 6)
        #expect(snapshot.health.ready == 5)
        #expect(snapshot.health.protectedFiles == 1)
        #expect(snapshot.health.recentlyAdded == 4)
        #expect(snapshot.health.lastScan == "8m ago")
        #expect(snapshot.syncStatusText == "Synced 8m ago")
        #expect(!snapshot.isPreviewBacked)
        #expect(snapshot.pipelineActivity.deltaCount == 7)
        #expect(snapshot.metrics.first { $0.id == "missing-genres" }?.trendUp == false)
        #expect(snapshot.metrics.first { $0.id == "missing-genres" }?.delta == "2")
        #expect(snapshot.metrics.first { $0.id == "missing-years" }?.trendUp == true)
        #expect(snapshot.metrics.first { $0.id == "missing-years" }?.delta == "1")
    }

    @Test("maps live tracks without cached metrics")
    func mapsLiveTracksWithoutCachedMetrics() {
        let tracks = [
            Core.Track(
                id: "1",
                name: "Tagged",
                artist: "Artist",
                album: "One",
                genre: "Rock",
                year: 2001,
                trackStatus: "purchased"
            ),
            Core.Track(
                id: "2",
                name: "Missing Genre",
                artist: "Artist",
                album: "One",
                year: 2002,
                trackStatus: "matched"
            ),
            Core.Track(
                id: "3",
                name: "Missing Year",
                artist: "Artist",
                album: "Two",
                genre: "Pop",
                trackStatus: "uploaded"
            ),
        ]

        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(tracks: tracks, lastScanDate: scanDate)
        )

        #expect(snapshot.health.totalTracks == 3)
        #expect(snapshot.health.missingGenre == 1)
        #expect(snapshot.health.missingYear == 1)
        #expect(snapshot.health.completeMetadata == 1)
        #expect(snapshot.health.protectedFiles == 0)
        #expect(snapshot.health.recentlyAdded == 0)
        #expect(snapshot.syncStatusText == "Synced 8m ago")
        #expect(snapshot.activity.first?.detail == "3 tracks analyzed")
    }

    @Test("keeps load error state ahead of library counts")
    func keepsLoadErrorStateAheadOfLibraryCounts() {
        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(
                tracks: [
                    Core.Track(
                        id: "1",
                        name: "Cached",
                        artist: "Artist",
                        album: "Album",
                        genre: "Rock",
                        year: 2001,
                        trackStatus: "purchased"
                    ),
                ],
                loadError: .failed("Music access failed")
            )
        )

        #expect(snapshot.health.totalTracks == 1)
        #expect(snapshot.pipelineActivity.title == "Library needs attention")
        #expect(snapshot.pipelineActivity.subtitle == "Music access failed")
        #expect(snapshot.pipelineActivity.status(for: .detect) == .failed)
        #expect(snapshot.pipelineActivity.primaryAction.title == "Retry scan")
    }

    @Test("maps empty library state without claiming a sync")
    func mapsEmptyLibraryStateWithoutClaimingSync() {
        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(from: makeInput())

        #expect(snapshot.health.totalTracks == 0)
        #expect(snapshot.health.lastScan == "No scan yet")
        #expect(snapshot.pipelineActivity.title == "Library empty")
        #expect(snapshot.syncStatusText == "No sync yet")
        #expect(snapshot.activity.first?.detail == "No tracks found")
    }

    @Test("maps workflow proposed accepted and failed counts")
    func mapsWorkflowProposedAcceptedAndFailedCounts() {
        let workflow = WorkflowDashboardState(
            proposedChangeCount: 9,
            acceptedChangeCount: 4,
            failedWriteCount: 2,
            isProcessing: false,
            phaseLabel: "Review"
        )

        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                workflow: workflow
            )
        )

        #expect(snapshot.pipelineActivity.deltaCount == 9)
        #expect(snapshot.pipelineActivity.failedWriteCount == 2)
        #expect(snapshot.pipelineActivity.status(for: .fix) == .failed)
        #expect(snapshot.health.ready == 4)
        #expect(snapshot.health.writeErrors == 2)
        #expect(snapshot.issues.first { $0.id == "errors" }?.count == "2")
        #expect(snapshot.issues.first { $0.id == "errors" }?.tone == .error)
    }

    @Test("maps pending verification summary when available")
    func mapsPendingVerificationSummaryWhenAvailable() {
        let pending = UpdateRunPendingVerificationSummary(
            total: 142,
            due: 12,
            problematic: 3,
            skippedByInterval: 5,
            verified: 7
        )

        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(pendingVerification: pending)
        )

        #expect(snapshot.health.pendingVerification == 142)
        #expect(snapshot.pipelineActivity.interventionCount == 142)
        #expect(snapshot.issues.first { $0.id == "pending" }?.count == "142")
        #expect(snapshot.issues.first { $0.id == "pending" }?.unit == "albums")
        #expect(snapshot.activity.contains { $0.detail == "142 albums queued, 12 due" })
    }

    @Test("marks pending verification unavailable when no summary is provided")
    func marksPendingVerificationUnavailableWhenNoSummaryIsProvided() {
        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(from: makeInput())

        #expect(snapshot.health.pendingVerification == 0)
        #expect(snapshot.pipelineActivity.interventionCount == 0)
        #expect(snapshot.issues.first { $0.id == "pending" }?.count == "Unavailable")
    }

    @Test("distinguishes auto sync running and stopped wording before first scan")
    func distinguishesAutoSyncRunningAndStoppedWordingBeforeFirstScan() {
        let running = DesignActivitySnapshotAdapter.makeSnapshot(from: makeInput(isAutoSyncRunning: true))
        let stopped = DesignActivitySnapshotAdapter.makeSnapshot(from: makeInput(isAutoSyncRunning: false))

        #expect(running.syncStatusText == "Auto-sync running")
        #expect(running.health.nextRun == "Auto-sync running")
        #expect(running.pipelineActivity.automationState == .autoSyncRunning)
        #expect(running.pipelineActivity.detail(for: .watch) == "Auto-sync running")
        #expect(running.pipelineActivity.detail(for: .detect) == "Polling enabled")
        #expect(stopped.syncStatusText == "No sync yet")
        #expect(stopped.health.nextRun == "Manual scan only")
        #expect(stopped.pipelineActivity.automationState == .noSyncYet)
        #expect(stopped.pipelineActivity.detail(for: .watch) == "No sync yet")
    }

    @Test("uses sync result wording only when a result exists")
    func usesSyncResultWordingOnlyWhenAResultExists() {
        let noResult = DesignActivitySnapshotAdapter.makeSnapshot(from: makeInput(lastScanDate: scanDate))
        let emptyResult = DesignActivitySnapshotAdapter.makeSnapshot(from: makeInput(lastSyncResult: SyncResult()))
        let changedResult = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(
                lastSyncResult: SyncResult(
                    newTracks: [editableTrack(id: "1")],
                    modifiedTracks: [editableTrack(id: "2")],
                    removedTrackIDs: ["3"]
                )
            )
        )

        #expect(noResult.syncStatusText == "Synced 8m ago")
        #expect(emptyResult.syncStatusText == "Synced · no changes")
        #expect(changedResult.syncStatusText == "Synced · 3 changes")
        #expect(changedResult.activity.contains { $0.detail == "3 library changes detected" })
    }

    private func makeInput(
        tracks: [Core.Track] = [],
        metricsSnapshot: PersistedMetricsSnapshot? = nil,
        lastScanDate: Date? = nil,
        isLoading: Bool = false,
        loadError: LibraryLoadError? = nil,
        isDryRun: Bool = true,
        workflow: WorkflowDashboardState = .empty,
        pendingVerification: UpdateRunPendingVerificationSummary? = nil,
        isAutoSyncRunning: Bool = false,
        lastSyncResult: SyncResult? = nil
    ) -> DesignActivitySnapshotInput {
        DesignActivitySnapshotInput(
            tracks: tracks,
            metricsSnapshot: metricsSnapshot,
            lastScanDate: lastScanDate,
            isLoading: isLoading,
            loadError: loadError,
            isDryRun: isDryRun,
            workflow: workflow,
            pendingVerification: pendingVerification,
            isAutoSyncRunning: isAutoSyncRunning,
            lastSyncResult: lastSyncResult,
            now: now
        )
    }

    private func editableTrack(id: String) -> Core.Track {
        Core.Track(
            id: id,
            name: "Song \(id)",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 2001,
            trackStatus: "purchased"
        )
    }
}
