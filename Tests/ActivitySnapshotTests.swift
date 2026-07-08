import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivitySnapshotAdapter")
struct ActivitySnapshotTests {
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

        let snapshot = makeSnapshot(from: makeInput(metricsSnapshot: metrics, workflow: workflow))

        #expect(snapshot.health.totalTracks == 10)
        #expect(snapshot.health.totalAlbums == nil)
        #expect(snapshot.health.missingGenre == 3)
        #expect(snapshot.health.missingYear == 2)
        #expect(snapshot.health.completeMetadata == 6)
        #expect(snapshot.health.ready == 5)
        #expect(snapshot.health.protectedFiles == 1)
        #expect(snapshot.health.recentlyAdded == 4)
        #expect(snapshot.health.lastScan == "8m ago")
        #expect(!snapshot.isPreviewBacked)
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
            )
        ]

        let snapshot = makeSnapshot(from: makeInput(tracks: tracks, lastScanDate: scanDate))

        #expect(snapshot.health.totalTracks == 3)
        #expect(snapshot.health.totalAlbums == 2)
        #expect(snapshot.health.missingGenre == 1)
        #expect(snapshot.health.missingYear == 1)
        #expect(snapshot.health.completeMetadata == 1)
        #expect(snapshot.health.protectedFiles == 0)
        #expect(snapshot.health.recentlyAdded == 0)
    }

    @Test("keeps load error state ahead of library counts")
    func keepsLoadErrorStateAheadOfLibraryCounts() {
        let snapshot = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                loadError: .failed("Music access failed")
            )
        )

        #expect(snapshot.health.totalTracks == 1)
    }

    @Test("maps empty library state without claiming a sync")
    func mapsEmptyLibraryStateWithoutClaimingSync() {
        let snapshot = makeSnapshot(from: makeInput())

        #expect(snapshot.health.totalTracks == 0)
        #expect(snapshot.health.lastScan == "No scan yet")
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

        let snapshot = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                workflow: workflow
            )
        )

        #expect(snapshot.health.ready == 4)
        #expect(snapshot.health.writeErrors == 2)
        #expect(snapshot.issues.first { $0.id == "errors" }?.count == "2")
        #expect(snapshot.issues.first { $0.id == "errors" }?.tone == .error)
    }

    @Test("maps dry run summary to the current scoped library tracks")
    func mapsDryRunSummaryToCurrentScopedLibraryTracks() {
        let workflow = WorkflowDashboardState(
            proposedChangeCount: 2,
            acceptedChangeCount: 0,
            failedWriteCount: 0,
            isProcessing: false,
            phaseLabel: "Review"
        )

        let snapshot = makeSnapshot(
            from: makeInput(
                tracks: [
                    editableTrack(id: "1"),
                    editableTrack(id: "2"),
                    editableTrack(id: "3")
                ],
                workflow: workflow
            )
        )

        #expect(snapshot.dryRun.changes == 2)
        #expect(snapshot.dryRun.tracks == 3)
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

        let snapshot = makeSnapshot(from: makeInput(pendingVerification: pending))

        #expect(snapshot.health.pendingVerification == 142)
        #expect(snapshot.pendingVerification.totalAlbums == 142)
        #expect(snapshot.pendingVerification.dueAlbums == 12)
        #expect(snapshot.pendingVerification.skippedByInterval == 5)
        #expect(snapshot.pendingVerification.problematicAlbums == 3)
        #expect(snapshot.pendingVerification.verifiedAlbums == 7)
        #expect(snapshot.pendingVerification.unavailableReason == nil)
        #expect(snapshot.issues.first { $0.id == "pending" }?.count == "142")
        #expect(snapshot.issues.first { $0.id == "pending" }?.unit == "albums")
    }

    @Test("marks pending verification unavailable when no summary is provided")
    func marksPendingVerificationUnavailableWhenNoSummaryIsProvided() {
        let snapshot = makeSnapshot(from: makeInput())

        #expect(snapshot.health.pendingVerification == 0)
        #expect(snapshot.pendingVerification.totalAlbums == 0)
        #expect(snapshot.pendingVerification
            .unavailableReason == "Pending verification data not available for this run")
        #expect(snapshot.issues.first { $0.id == "pending" }?.count == "Unavailable")
    }

    @Test("distinguishes auto sync running and stopped wording before first scan")
    func distinguishesAutoSyncRunningAndStoppedWordingBeforeFirstScan() {
        let running = makeSnapshot(from: makeInput(isAutoSyncRunning: true))
        let stopped = makeSnapshot(from: makeInput(isAutoSyncRunning: false))

        #expect(running.health.nextRun == "Auto-sync running")
        #expect(stopped.health.nextRun == "Manual scan only")
    }

    @Test("maps next run from run lifecycle")
    func mapsLifecycleNextRun() {
        let syncing = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(phase: .active(.syncingLibrary))
            )
        )
        let failed = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(phase: .finished(
                    .failed(message: "AppleScript timeout"),
                    finishedAt: now
                ))
            )
        )
        let blocked = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(phase: .suspended(.blocked))
            )
        )
        let recoverable = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(phase: .suspended(.recoverable))
            )
        )
        let cancelled = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(phase: .finished(
                    .cancelled(message: "User cancelled"),
                    finishedAt: now
                ))
            )
        )

        #expect(syncing.health.nextRun == "Manual sync running")
        #expect(failed.health.nextRun == "Manual sync failed")
        #expect(blocked.health.nextRun == "Manual sync blocked")
        #expect(recoverable.health.nextRun == "Manual sync needs recovery")
        #expect(cancelled.health.nextRun == "Manual sync cancelled")
    }

    private func makeSnapshot(from input: DesignActivitySnapshotInput) -> DesignDataSnapshot {
        ActivitySnapshotAdapter.makeSnapshot(from: input, activityProjection: .empty())
    }

    private func makeInput(
        tracks: [Core.Track] = [],
        metricsSnapshot: PersistedMetricsSnapshot? = nil,
        lastScanDate: Date? = nil,
        loadError: LibraryLoadError? = nil,
        workflow: WorkflowDashboardState = .empty,
        pendingVerification: UpdateRunPendingVerificationSummary? = nil,
        changeLogEntries: [Core.ChangeLogEntry] = [],
        isAutoSyncRunning: Bool = false,
        runLifecycle: RunLifecycleSnapshot? = nil
    ) -> DesignActivitySnapshotInput {
        DesignActivitySnapshotInput(
            tracks: tracks,
            metricsSnapshot: metricsSnapshot,
            lastScanDate: lastScanDate,
            isLoading: false,
            loadError: loadError,
            isDryRun: true,
            workflow: workflow,
            pendingVerification: pendingVerification,
            changeLogEntries: changeLogEntries,
            isAutoSyncRunning: isAutoSyncRunning,
            runLifecycle: runLifecycle,
            settings: .preview,
            now: now
        )
    }

    private func makeRunLifecycle(phase: RunPhase) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: .capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: scanDate,
                reason: "test"
            ),
            startedAt: scanDate,
            phase: phase
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
