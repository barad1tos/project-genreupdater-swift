import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow pending verification")
@MainActor
struct PendingWorkflowTests {
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

    @Test("recovery hold blocks direct pending verification")
    func recoveryHoldBlocksDirectPendingVerification() async {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.hasRecoveryHold = { true }
        }
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())
        await viewModel.processingTask?.value
        await Task.yield()

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "recovery hold should stop pending verification writes")
            return
        }
        #expect(message == "Previous run needs recovery before writes continue.")
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
        #expect(await pendingVerification.removedAlbums().isEmpty)
    }

    @Test("auto verifies due pending albums before live full-library batch")
    func autoVerifiesDuePendingAlbumsBeforeLiveFullLibraryBatch() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
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
        let run = makeRandomAccessLiveBatchRun(preflightState: .notDue)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await run.pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-batch-year"])
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.map(\.trackID) == ["batch-year"])
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 1)
    }

    @Test("skips auto verification when maintenance preflight is unavailable")
    func skipsAutoVerificationWhenMaintenancePreflightIsUnavailable() async throws {
        let run = makeRandomAccessLiveBatchRun(preflightState: .unavailable)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await run.pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-batch-year"])
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.map(\.trackID) == ["batch-year"])
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 1)
    }

    @Test("prepares due pending albums outside the incremental batch scope")
    func preparesDuePendingAlbumsOutsideIncrementalBatchScope() async throws {
        let recorder = PendingMutationPreparationRecorder()
        let batchTrack = batchYearTrack()
        let batchTrackIDs = Set([batchTrack.id])
        let idMapper = WorkflowTrackIDMapper(
            enrichedTracks: [batchTrack],
            appleScriptIDsByMusicKitID: [batchTrack.id: "as-\(batchTrack.id)"]
        )
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.additionalEnrichedTracks = [batchTrack]
            options.idMapper = idMapper
            options.resolveIncrementalTracks = { tracks, _ in
                tracks.filter { batchTrackIDs.contains($0.id) }
            }
            options.runMaintenancePreflight = { pendingDuePreflight() }
            options.prepareMutationMetadata = { tracks in
                await recorder.record(tracks)
                guard tracks.contains(where: { $0.id == "ram-1" || $0.id == "ram-2" }) else {
                    return
                }
                await idMapper.seed(
                    enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                    appleScriptIDsByMusicKitID: [
                        "ram-1": "as-ram-1",
                        "ram-2": "as-ram-2",
                    ]
                )
            }
        }
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks() + [batchTrack])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let preparedTrackIDBatches = await recorder.preparedTrackIDBatches()
        let writes = await fixture.scriptClient.updatedProperties()

        #expect(preparedTrackIDBatches.count == 2)
        #expect(preparedTrackIDBatches.first == ["batch-year"])
        if preparedTrackIDBatches.count > 1 {
            #expect(Set(preparedTrackIDBatches[1]) == Set(["ram-1", "ram-2"]))
        }
        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2", "as-batch-year"])
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
    }

    @Test("does not auto verify pending albums during reviewed dry run")
    func doesNotAutoVerifyPendingAlbumsDuringReviewedDryRun() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
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
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
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
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
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
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let run = makeRandomAccessLiveBatchRun(
            pendingVerificationService: pendingVerification,
            failingWriteTrackIDs: ["as-ram-2"],
        )
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-ram-1"])
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.map(\.trackID) == ["ram-1"])
        #expect(viewModel.result?.failedTrackIDs == ["ram-2"])
        #expect(viewModel.failedTracks.contains { $0.id == "ram-2" })
        #expect(viewModel.failedCount == 1)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 0)
    }

    @Test("successful preflight entries stay visible after live batch")
    func successfulPreflightEntriesStayVisibleAfterLiveBatch() async throws {
        let run = makeRandomAccessLiveBatchRun()
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let completedTrackIDs = viewModel.completedEntries.map(\.trackID)

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "successful preflight and live batch should finish")
            return
        }
        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2", "as-batch-year"])
        #expect(completedTrackIDs == ["ram-1", "ram-2", "batch-year"])
        #expect(viewModel.result?.entries.map(\.trackID) == completedTrackIDs)
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.errorDescriptions.isEmpty == true)
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.trackStatuses["batch-year"] == .done)
        #expect(viewModel.processedCount == 3)
        #expect(viewModel.failedCount == 0)
        #expect(viewModel.progress == nil)
        #expect(viewModel.pendingVerificationReportSummary == nil)
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(await run.timestampUpdates.count() == 1)
    }

    @Test("no-op resolved preflight statuses stay visible after live batch")
    func noOpResolvedPreflightStatusesStayVisibleAfterLiveBatch() async throws {
        let run = makeRandomAccessLiveBatchRun(randomAccessYear: 2013)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run, randomAccessYear: 2013)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await run.pendingVerification.removedAlbums()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "no-op preflight and live batch should finish")
            return
        }
        #expect(writes.map(\.trackID) == ["as-batch-year"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["batch-year"])
        #expect(viewModel.trackStatuses["ram-1"] == .done)
        #expect(viewModel.trackStatuses["ram-2"] == .done)
        #expect(viewModel.trackStatuses["batch-year"] == .done)
        #expect(viewModel.processedCount == 3)
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(await run.timestampUpdates.count() == 1)
    }

    @Test("pending-only empty incremental preflight does not update run timestamp")
    func pendingOnlyEmptyIncrementalPreflightDoesNotUpdateRunTimestamp() async throws {
        let timestampUpdates = PendingTimestampUpdateCounter()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.resolveIncrementalTracks = { _, _ in [] }
            options.runMaintenancePreflight = { pendingDuePreflight() }
            options.updateIncrementalRunTimestamp = {
                await timestampUpdates.record()
            }
        }
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

    @Test("auto verifies due pending albums when incremental batch is empty")
    func autoVerifiesDuePendingAlbumsWhenIncrementalBatchIsEmpty() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.resolveIncrementalTracks = { _, _ in [] }
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
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
        #expect(summary.problematicDetails.map(\.album) == ["Pure Rock Fury", "Noise"])
        #expect(summary.problematicDetails.map(\.attemptCount) == [3, 4])
        #expect(summary.problematicDetails.allSatisfy { $0.nextVerification > $0.lastAttempt })

        viewModel.maintenancePreflightResult = staleDatabaseVerificationPreflight()
        viewModel.startPendingVerification(tracks: [])
        #expect(viewModel.maintenancePreflightResult == nil)
        try await waitForWorkflowToLeaveScanning(viewModel)

        let pendingOnlyReport = UpdateRunReport(
            result: viewModel.result,
            completedEntries: viewModel.completedEntries,
            trackStatuses: viewModel.trackStatuses,
            tracks: [],
            testArtists: [],
            operationalContext: UpdateRunOperationalContext(
                pendingVerification: viewModel.pendingVerificationReportSummary,
                databaseVerification: UpdateRunDatabaseVerificationSummary(
                    preflightResult: viewModel.maintenancePreflightResult
                )
            )
        )
        #expect(!pendingOnlyReport.plainTextSummary.contains("Database Verification"))

        viewModel.reset()
        #expect(viewModel.pendingVerificationReportSummary == nil)
        #expect(viewModel.maintenancePreflightResult == nil)

        viewModel.pendingVerificationReportSummary = summary
        viewModel.maintenancePreflightResult = staleDatabaseVerificationPreflight()
        viewModel.mode = .selectedTracks
        viewModel.start(tracks: [])
        #expect(viewModel.pendingVerificationReportSummary == nil)
        #expect(viewModel.maintenancePreflightResult == nil)
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
}

actor PendingMutationPreparationRecorder {
    private var batches: [[String]] = []

    func record(_ tracks: [Track]) {
        batches.append(tracks.map(\.id))
    }

    func preparedTrackIDBatches() -> [[String]] {
        batches
    }
}
