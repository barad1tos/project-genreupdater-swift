import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow pending verification")
@MainActor
struct WorkflowPendingTests {
    @Test("ignores unrelated missing canonical guest album title")
    func ignoresUnrelatedMissingCanonicalGuestAlbumTitle() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: [
                    randomAccessMemoriesTracksWithAlbumArtist()[0],
                ],
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: [
            Track(
                id: "ram-1",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories"
            ),
            Track(
                id: "other-ram",
                name: "Unrelated Song",
                artist: "Other Artist",
                album: "Random Access Memories"
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
    }

    @Test("keeps non-definitive same-year albums pending")
    func keepsNonDefinitiveSameYearAlbumsPending() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let fixture = makeWorkflowFixture(
            apiServices: APIOrchestratorServices(
                musicBrainz: DashboardStateAPIService(year: 2013, confidence: 60, isDefinitive: false),
                discogs: DashboardStateAPIService(),
                appleMusic: DashboardStateAPIService()
            ),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(year: 2013),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks(year: 2013))

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()
        let remainingPending = await pendingVerification.getAllPendingAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(remainingPending.map(\.id) == ["daft-punk-random-access-memories"])
        #expect(viewModel.completedEntries.isEmpty)
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
    }

    @Test("refreshes pending report summary after resolved albums are cleared")
    func refreshesPendingReportSummaryAfterResolvedAlbumsAreCleared() async throws {
        let pendingRun = makeRandomAccessPendingViewModel()
        let viewModel = pendingRun.viewModel

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let removals = await pendingRun.pendingFixture.service.removedAlbums()
        let remainingPending = await pendingRun.pendingFixture.service.getAllPendingAlbums()
        let summary = try #require(viewModel.pendingVerificationReportSummary)

        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(remainingPending.map(\.id) == ["clutch-pure-rock-fury"])
        expectPendingSummary(summary, total: 1, due: 0, problematic: 0)
    }

    @Test("auto verifies due pending albums before live full-library batch")
    func autoVerifiesDuePendingAlbumsBeforeLiveFullLibraryBatch() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(writes.map(\.property) == ["year", "year"])
        #expect(writes.map(\.value) == ["2013", "2013"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
    }

    @Test("skips auto verification when maintenance preflight is not due")
    func skipsAutoVerificationWhenMaintenancePreflightIsNotDue() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            runMaintenancePreflight: { pendingNotDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("skips auto verification when maintenance preflight is unavailable")
    func skipsAutoVerificationWhenMaintenancePreflightIsUnavailable() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            runMaintenancePreflight: { nil }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("does not auto verify pending albums during reviewed dry run")
    func doesNotAutoVerifyPendingAlbumsDuringReviewedDryRun() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .selectedTracks
        viewModel.previewOnly = true

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("does not auto verify pending albums during selected live review")
    func doesNotAutoVerifyPendingAlbumsDuringSelectedLiveReview() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .selectedTracks
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("does not auto verify pending albums during full-library preview")
    func doesNotAutoVerifyPendingAlbumsDuringFullLibraryPreview() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("preflight pending failures stop live batch and stay visible")
    func preflightPendingFailuresStopLiveBatchAndStayVisible() async throws {
        let batchTrack = Track(
            id: "batch-year",
            name: "Batch Year",
            artist: "Clutch",
            album: "Pure Rock Fury",
            year: 1999
        )
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            failingWriteTrackIDs: ["as-ram-2"],
            additionalEnrichedTracks: [batchTrack],
            additionalAppleScriptIDsByMusicKitID: ["batch-year": "as-batch-year"],
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == batchTrack.id }
            },
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks() + [batchTrack])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1"])
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1"])
        #expect(viewModel.result?.failedTrackIDs == ["ram-2"])
        #expect(viewModel.failedTracks.contains { $0.id == "ram-2" })
        #expect(viewModel.failedCount == 1)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
    }

    @Test("successful preflight entries stay visible after live batch")
    func successfulPreflightEntriesStayVisibleAfterLiveBatch() async throws {
        let batchTrack = Track(
            id: "batch-year",
            name: "Batch Year",
            artist: "Clutch",
            album: "Pure Rock Fury",
            year: 1999
        )
        let timestampUpdates = PendingTimestampUpdateCounter()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            additionalEnrichedTracks: [batchTrack],
            additionalAppleScriptIDsByMusicKitID: ["batch-year": "as-batch-year"],
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == batchTrack.id }
            },
            runMaintenancePreflight: { pendingDuePreflight() },
            updateIncrementalRunTimestamp: {
                await timestampUpdates.record()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks() + [batchTrack])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let completedTrackIDs = viewModel.completedEntries.map(\.trackID)

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2", "as-batch-year"])
        #expect(completedTrackIDs == ["ram-1", "ram-2", "batch-year"])
        #expect(viewModel.result?.entries.map(\.trackID) == completedTrackIDs)
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.trackStatuses["batch-year"] == .done)
        #expect(viewModel.processedCount == 3)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(await timestampUpdates.count() == 1)
    }

    @Test("pending-only empty incremental preflight does not update run timestamp")
    func pendingOnlyEmptyIncrementalPreflightDoesNotUpdateRunTimestamp() async throws {
        let timestampUpdates = PendingTimestampUpdateCounter()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            resolveIncrementalTracks: { _, _ in [] },
            runMaintenancePreflight: { pendingDuePreflight() },
            updateIncrementalRunTimestamp: {
                await timestampUpdates.record()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(await timestampUpdates.count() == 0)
    }

    @Test("cancelling pending preflight does not start live batch")
    func cancellingPendingPreflightDoesNotStartLiveBatch() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            cancellingWriteTrackIDs: ["as-ram-1"],
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToReturnToConfigure(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.isEmpty)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
    }

    @Test("auto verifies due pending albums when incremental batch is empty")
    func autoVerifiesDuePendingAlbumsWhenIncrementalBatchIsEmpty() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification,
            resolveIncrementalTracks: { _, _ in [] },
            runMaintenancePreflight: { pendingDuePreflight() }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = false

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.processedCount == 2)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
    }

    @Test("ignores stale pending scope refresh after pending run")
    func ignoresStalePendingScopeRefreshAfterPendingRun() async throws {
        let pendingSnapshotDelay = PendingSnapshotDelay()
        let pendingRun = makeRandomAccessPendingViewModel(
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let viewModel = pendingRun.viewModel

        try await computeDelayedPendingScopePreview(
            viewModel: viewModel,
            tracks: randomAccessMemoriesMusicKitTracks(),
            pendingSnapshotDelay: pendingSnapshotDelay
        )

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())
        try await waitForWorkflowToLeaveScanning(viewModel)
        let finalSummary = try #require(viewModel.pendingVerificationReportSummary)
        expectPendingSummary(finalSummary, total: 1, due: 0, problematic: 0)

        await pendingSnapshotDelay.releaseFirstSnapshot()
        try await pendingSnapshotDelay.waitForDelayedPendingScopeRefreshCompletion()

        let summary = try #require(viewModel.pendingVerificationReportSummary)
        expectPendingSummary(summary, total: 1, due: 0, problematic: 0)
    }

    @Test("summarizes pending snapshot facts for update run reports")
    func summarizesPendingSnapshotFactsForUpdateRunReports() async throws {
        let dueEntry = randomAccessMemoriesPendingEntry()
        let problematicEntry = pureRockFuryPendingEntry()
        let skippedProblematicEntry = noisePendingEntry()
        let pendingSnapshotDelay = PendingSnapshotDelay()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [dueEntry, problematicEntry, skippedProblematicEntry],
            dueEntries: [dueEntry],
            problematicAlbums: [
                problematicPendingAlbum(entry: problematicEntry),
                problematicPendingAlbum(entry: skippedProblematicEntry, attempts: 4, daysSinceFirstAttempt: 21),
            ],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let viewModel = makeWorkflowFixture(pendingVerificationService: pendingVerification).viewModel
        viewModel.mode = .pendingVerification

        try await computeDelayedPendingScopePreview(
            viewModel: viewModel,
            tracks: [],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        await pendingSnapshotDelay.releaseFirstSnapshot()
        try await pendingSnapshotDelay.waitForDelayedPendingScopeRefreshCompletion()

        let summary = try #require(viewModel.pendingVerificationReportSummary)
        expectPendingSummary(summary, total: 3, due: 1, problematic: 2)

        viewModel.reset()
        #expect(viewModel.pendingVerificationReportSummary == nil)

        viewModel.pendingVerificationReportSummary = summary
        viewModel.mode = .selectedTracks
        viewModel.start(tracks: [])
        #expect(viewModel.pendingVerificationReportSummary == nil)
    }

    @Test("uses configured problematic album threshold for pending report summaries")
    func usesConfiguredProblematicAlbumThresholdForPendingReportSummaries() async throws {
        let dueEntry = randomAccessMemoriesPendingEntry()
        let retryingEntry = pureRockFuryPendingEntry()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [dueEntry, retryingEntry],
            dueEntries: [dueEntry],
            problematicAlbums: [
                problematicPendingAlbum(entry: retryingEntry, attempts: 4, daysSinceFirstAttempt: 21),
            ]
        )
        let viewModel = makeWorkflowFixture(
            pendingVerificationService: pendingVerification,
            problematicAlbumReportMinAttempts: { 5 }
        ).viewModel
        viewModel.mode = .pendingVerification

        viewModel.computeScopePreview(tracks: [])

        for _ in 0 ..< 200 {
            if let summary = viewModel.pendingVerificationReportSummary {
                expectPendingSummary(summary, total: 2, due: 1, problematic: 0)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(Bool(false), "pending verification summary did not refresh before timeout")
    }

    private struct RandomAccessPendingFixture {
        let service: WorkflowPendingVerificationService
    }

    private struct RandomAccessPendingRun {
        let pendingFixture: RandomAccessPendingFixture
        let viewModel: WorkflowViewModel
    }

    private func expectPendingSummary(
        _ summary: UpdateRunPendingVerificationSummary,
        total: Int,
        due: Int,
        problematic: Int
    ) {
        #expect(summary.total == total)
        #expect(summary.due == due)
        #expect(summary.problematic == problematic)
    }

    private func waitForWorkflowToReturnToConfigure(_ viewModel: WorkflowViewModel) async throws {
        for _ in 0 ..< 500 {
            if case .configure = viewModel.phase {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(Bool(false), "workflow did not return to configure before timeout")
    }

    private func makeRandomAccessPendingViewModel(
        pendingSnapshotDelay: PendingSnapshotDelay? = nil
    ) -> RandomAccessPendingRun {
        let pendingFixture = makeRandomAccessPendingFixture(
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingFixture.service
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification
        return RandomAccessPendingRun(pendingFixture: pendingFixture, viewModel: viewModel)
    }

    private func makeRandomAccessWorkflowFixture(
        pendingVerificationService: WorkflowPendingVerificationService,
        failingWriteTrackIDs: Set<String> = [],
        cancellingWriteTrackIDs: Set<String> = [],
        additionalEnrichedTracks: [Track] = [],
        additionalAppleScriptIDsByMusicKitID: [String: String] = [:],
        resolveIncrementalTracks: @escaping (
            [Track],
            IncrementalTrackScopeOptions
        ) async -> [Track] = { tracks, _ in tracks },
        runMaintenancePreflight: (() async -> MaintenancePreflightResult?)? = nil,
        updateIncrementalRunTimestamp: (() async -> Void)? = nil
    ) -> WorkflowFixture {
        makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            failingWriteTrackIDs: failingWriteTrackIDs,
            cancellingWriteTrackIDs: cancellingWriteTrackIDs,
            resolveIncrementalTracks: resolveIncrementalTracks,
            pendingVerificationService: pendingVerificationService,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist() + additionalEnrichedTracks,
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ].merging(additionalAppleScriptIDsByMusicKitID) { current, _ in current }
            ),
            runMaintenancePreflight: runMaintenancePreflight,
            updateIncrementalRunTimestamp: updateIncrementalRunTimestamp
        )
    }

    private func makeRandomAccessPendingFixture(
        pendingSnapshotDelay: PendingSnapshotDelay? = nil
    ) -> RandomAccessPendingFixture {
        let resolvedEntry = randomAccessMemoriesPendingEntry()
        let skippedEntry = pureRockFuryPendingEntry()
        let service = WorkflowPendingVerificationService(
            entries: [resolvedEntry, skippedEntry],
            dueEntries: [resolvedEntry],
            problematicAlbums: [problematicPendingAlbum(entry: resolvedEntry)],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        return RandomAccessPendingFixture(service: service)
    }

    private func randomAccessMemoriesPendingEntry() -> PendingAlbumEntry {
        pendingEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories"
        )
    }

    private func pureRockFuryPendingEntry() -> PendingAlbumEntry {
        pendingEntry(
            id: "clutch-pure-rock-fury",
            artist: "Clutch",
            album: "Pure Rock Fury"
        )
    }

    private func noisePendingEntry() -> PendingAlbumEntry {
        pendingEntry(id: "archive-noise", artist: "Archive", album: "Noise")
    }

    private func pendingEntry(id: String, artist: String, album: String) -> PendingAlbumEntry {
        PendingAlbumEntry(
            id: id,
            artist: artist,
            album: album,
            reason: "no_year_found"
        )
    }

    private func problematicPendingAlbum(
        entry: PendingAlbumEntry,
        attempts: Int = 3,
        daysSinceFirstAttempt: Int = 14
    ) -> ProblematicPendingAlbum {
        let attemptDate = Date(timeIntervalSince1970: 1_700_000_000)
        return ProblematicPendingAlbum(
            entry: entry,
            totalAttempts: attempts,
            firstAttempt: attemptDate,
            lastAttempt: attemptDate,
            daysSinceFirstAttempt: daysSinceFirstAttempt
        )
    }

    private func pendingDuePreflight() -> MaintenancePreflightResult {
        MaintenancePreflightResult(
            databaseVerification: nil,
            databaseVerificationError: nil,
            isPendingVerificationDue: true
        )
    }

    private func pendingNotDuePreflight() -> MaintenancePreflightResult {
        MaintenancePreflightResult(
            databaseVerification: nil,
            databaseVerificationError: nil,
            isPendingVerificationDue: false
        )
    }
}

private actor PendingTimestampUpdateCounter {
    private var updates = 0

    func record() {
        updates += 1
    }

    func count() -> Int {
        updates
    }
}
