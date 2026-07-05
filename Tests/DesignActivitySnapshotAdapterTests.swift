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
            ),
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
                    editableTrack(id: "3"),
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
    func mapsNextRunFromActiveRunLifecycle() {
        let syncing = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(state: .syncingLibrary)
            )
        )
        let failed = makeSnapshot(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                lastScanDate: scanDate,
                runLifecycle: makeRunLifecycle(state: .failed)
            )
        )

        #expect(syncing.health.nextRun == "Manual sync running")
        #expect(failed.health.nextRun == "Manual sync failed")
    }

    @Test("maps persisted change log entries for read-only reports")
    func mapsPersistedChangeLogEntriesForReadOnlyReports() throws {
        let genreID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let yearID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let renameID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let entries = [
            Core.ChangeLogEntry(
                id: genreID,
                timestamp: scanDate,
                changeType: .genreUpdate,
                trackID: "track-genre",
                artist: "Metallica",
                trackName: "Battery",
                albumName: "Master of Puppets",
                oldGenre: "Metal",
                newGenre: "Thrash Metal"
            ),
            Core.ChangeLogEntry(
                id: yearID,
                timestamp: scanDate.addingTimeInterval(-60),
                changeType: .yearUpdate,
                trackID: "track-year",
                artist: "Radiohead",
                trackName: "Idioteque",
                albumName: "Kid A",
                oldYear: nil,
                newYear: 2000
            ),
            Core.ChangeLogEntry(
                id: renameID,
                timestamp: scanDate.addingTimeInterval(-120),
                changeType: .artistRename,
                trackID: "track-artist",
                artist: "Aphex Twin",
                trackName: "Windowlicker",
                albumName: "Windowlicker",
                oldArtist: "AFX",
                newArtist: "Aphex Twin"
            ),
        ]

        let snapshot = makeSnapshot(from: makeInput(changeLogEntries: entries))

        #expect(snapshot.changeLog.map(\.id) == [genreID.uuidString, yearID.uuidString, renameID.uuidString])
        #expect(snapshot.changeLog[0].time == "8m ago")
        #expect(snapshot.changeLog[0].type == .genre)
        #expect(snapshot.changeLog[0].old == "Metal")
        #expect(snapshot.changeLog[0].new == "Thrash Metal")
        #expect(snapshot.changeLog[0].conf == nil)
        #expect(snapshot.changeLog[2].type == .artist)
        #expect(snapshot.changeLog[2].old == "AFX")
        #expect(snapshot.reportStats.processed == 3)
        #expect(snapshot.reportStats.genres == 1)
        #expect(snapshot.reportStats.years == 1)
        #expect(snapshot.genreDistribution.first?.label == "Thrash Metal")
        #expect(snapshot.yearDistribution.first?.label == "2000s")
        #expect(snapshot.updatesOverTime.map(\.count).reduce(0, +) == entries.count)
    }

    @Test("maps persisted change log branch variants for read-only reports")
    func mapsPersistedChangeLogBranchVariantsForReadOnlyReports() throws {
        let trackID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let albumID = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let revertID = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let entries = [
            Core.ChangeLogEntry(
                id: trackID,
                timestamp: scanDate,
                changeType: .trackCleaning,
                trackID: "track-clean",
                artist: "Aphex Twin",
                trackName: "",
                albumName: "Windowlicker",
                oldTrackName: "Windowlicker [Remastered]",
                newTrackName: "Windowlicker"
            ),
            Core.ChangeLogEntry(
                id: albumID,
                timestamp: scanDate.addingTimeInterval(-60),
                changeType: .albumCleaning,
                trackID: "album-clean",
                artist: "Boards of Canada",
                trackName: "Roygbiv",
                albumName: "Music Has the Right to Children",
                oldAlbumName: "Music Has the Right to Children (Expanded)",
                newAlbumName: "Music Has the Right to Children"
            ),
            Core.ChangeLogEntry(
                id: revertID,
                timestamp: scanDate.addingTimeInterval(-120),
                changeType: .yearRevert,
                trackID: "year-revert",
                artist: "Boards of Canada",
                trackName: "",
                albumName: "",
                oldYear: 2024,
                newYear: 1998
            ),
        ]

        let snapshot = makeSnapshot(from: makeInput(changeLogEntries: entries))

        #expect(snapshot.changeLog[0].type == .track)
        #expect(snapshot.changeLog[0].track == "Windowlicker")
        #expect(snapshot.changeLog[0].old == "Windowlicker [Remastered]")
        #expect(snapshot.changeLog[0].new == "Windowlicker")
        #expect(snapshot.changeLog[1].type == .album)
        #expect(snapshot.changeLog[1].old == "Music Has the Right to Children (Expanded)")
        #expect(snapshot.changeLog[1].new == "Music Has the Right to Children")
        #expect(snapshot.changeLog[2].type == .revert)
        #expect(snapshot.changeLog[2].track == "year-revert")
        #expect(snapshot.changeLog[2].old == "2024")
        #expect(snapshot.changeLog[2].new == "1998")
        #expect(snapshot.reportStats.processed == 3)
        #expect(snapshot.reportStats.genres == 0)
        #expect(snapshot.reportStats.years == 1)
    }

    @Test("keeps genre chart identifiers collision proof")
    func keepsGenreChartIdentifiersCollisionProof() throws {
        let dashedID = try #require(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let spacedID = try #require(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let entries = [
            Core.ChangeLogEntry(
                id: dashedID,
                timestamp: scanDate,
                changeType: .genreUpdate,
                trackID: "genre-dashed",
                artist: "Artist",
                trackName: "Track",
                albumName: "Album",
                newGenre: "Hip-Hop"
            ),
            Core.ChangeLogEntry(
                id: spacedID,
                timestamp: scanDate.addingTimeInterval(-60),
                changeType: .genreUpdate,
                trackID: "genre-spaced",
                artist: "Artist",
                trackName: "Track",
                albumName: "Album",
                newGenre: "Hip Hop"
            ),
        ]

        let snapshot = makeSnapshot(from: makeInput(changeLogEntries: entries))
        let identifiers = snapshot.genreDistribution.map(\.id)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.contains("genre-7-Hip-Hop"))
        #expect(identifiers.contains("genre-7-Hip Hop"))
    }

    @Test("maps reports projection into run history")
    func mapsReportsProjectionIntoRunHistory() {
        let run = ReportsRunItem(
            id: "run-1",
            state: .completed,
            stateLabel: "Completed",
            triggerLabel: "Manual check",
            startedLabel: "2m ago",
            durationLabel: "45s",
            changeCountLabel: "12 changes",
            failureSummary: nil
        )
        let projection = ReportsProjection(revision: .initial, runs: [run], skippedCorruptedCount: 2)

        let snapshot = DesignActivitySnapshotAdapter.makeSnapshot(
            from: makeInput(),
            activityProjection: .empty(),
            reportsProjection: projection
        )

        #expect(snapshot.runHistory.count == 1)
        #expect(snapshot.runHistory.first?.id == "run-1")
        #expect(snapshot.runHistory.first?.stateLabel == "Completed")
        #expect(snapshot.runHistorySkippedCount == 2)
    }

    @Test("omitted reports projection yields empty run history")
    func omittedReportsProjectionYieldsEmptyRunHistory() {
        let snapshot = makeSnapshot(from: makeInput())

        #expect(snapshot.runHistory.isEmpty)
        #expect(snapshot.runHistorySkippedCount == 0)
    }

    private func makeSnapshot(from input: DesignActivitySnapshotInput) -> DesignDataSnapshot {
        DesignActivitySnapshotAdapter.makeSnapshot(from: input, activityProjection: .empty())
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

    private func makeRunLifecycle(state: RunLifecycleState) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            state: state,
            scope: .capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: scanDate,
                reason: "test"
            ),
            syncResult: nil,
            failureMessage: state == .failed ? "AppleScript timeout" : nil,
            startedAt: scanDate,
            finishedAt: isTerminalRunState(state) ? now : nil
        )
    }

    private func isTerminalRunState(_ state: RunLifecycleState) -> Bool {
        switch state {
        case .completed, .completedNoOp, .failed:
            true
        case .created, .syncingLibrary, .reporting:
            false
        }
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
