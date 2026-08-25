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

        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1"])
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
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(year: 2013),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            ),
            configure: { options in
                options.apiServices = APIOrchestratorServices(
                    musicBrainz: DashboardStateAPIService(year: 2013, confidence: 60, isDefinitive: false),
                    discogs: DashboardStateAPIService(),
                    appleMusic: DashboardStateAPIService()
                )
            }
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
            options.ensureRecoveryHold = { true }
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

        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1", "as-ram-2"])
        #expect(writes.map(\.property) == [.year, .year])
        #expect(writes.map(\.value) == ["2013", "2013"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(viewModel.completedEntries.map(\.trackID) == ["as-ram-1", "as-ram-2"])
    }

    @Test("successful year preflight preserves primary metadata stages")
    func preflightKeepsPrimaryStages() async throws {
        let tracks = pendingCleaningTracks()
        let enrichedTracks = pendingCleaningTracks(
            trackStatus: TrackKind.subscription.rawValue,
            albumArtist: "Daft Punk"
        )
        let pendingEntry = randomAccessMemoriesPendingEntry()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [pendingEntry],
            dueEntries: [pendingEntry]
        )
        func isPrimaryTrack(_ track: Track) -> Bool {
            track.id == "ram-1"
        }
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.idMapper = WorkflowTrackIDMapper(
                enrichedTracks: enrichedTracks,
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
            options.resolveIncrementalTracks = { tracks, _ in
                tracks.filter(isPrimaryTrack)
            }
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.cleanTrackNames = true

        viewModel.start(tracks: tracks)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let cleanedNameWrite = writes.first { $0.property == .name }

        #expect(writes.filter { $0.property == .year }.count == 2)
        #expect(cleanedNameWrite?.databaseID.rawValue == "as-ram-1")
        #expect(cleanedNameWrite?.value == "Get Lucky")
        #expect(viewModel.scopeTrackCount == 2)
        #expect(viewModel.processedCount == 2)
    }

    @Test("force year lookup rechecks pending overlap after cache invalidation")
    func forceRechecksPendingYear() async throws {
        let lookupProbe = YearLookupProbe()
        let pendingEntry = randomAccessMemoriesPendingEntry()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [pendingEntry],
            dueEntries: [pendingEntry]
        )
        let apiService = DashboardStateAPIService(
            year: 2013,
            confidence: 100,
            beforeAlbumYearLookup: {
                await lookupProbe.recordLookup()
            }
        )
        let fixture = makeWorkflowFixture(
            apiService: apiService,
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            ),
            configure: { options in
                options.runMaintenancePreflight = { pendingDuePreflight() }
                options.invalidateAlbumYearCache = {
                    await lookupProbe.recordInvalidation()
                }
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.forceYearLookup = true

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await lookupProbe.invalidationCount() == 1)
        let lookupStates = await lookupProbe.statesAtLookup()
        #expect(lookupStates.first == 0)
        #expect(lookupStates.contains(1))
    }

    @Test("not-due preflight skips maintenance while the batch resolves processed albums")
    func notDueSkipsMaintenance() async throws {
        let run = makeRandomAccessLiveBatchRun(preflightState: .notDue)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await run.pendingVerification.removedAlbums()

        #expect(Set(writes.map(\.databaseID.rawValue)) == Set(["as-batch-year", "as-ram-1", "as-ram-2"]))
        #expect(removals.count == 2)
        #expect(removals.contains { $0.artist == "Clutch" && $0.album == "Pure Rock Fury" })
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(Set(viewModel.completedEntries.map(\.trackID)) == Set(["as-batch-year", "as-ram-1", "as-ram-2"]))
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 1)
    }

    @Test("unavailable preflight skips maintenance while the batch resolves processed albums")
    func unavailableSkipsMaintenance() async throws {
        let run = makeRandomAccessLiveBatchRun(preflightState: .unavailable)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await run.fixture.scriptClient.updatedProperties()
        let removals = await run.pendingVerification.removedAlbums()

        #expect(Set(writes.map(\.databaseID.rawValue)) == Set(["as-batch-year", "as-ram-1", "as-ram-2"]))
        #expect(removals.count == 2)
        #expect(removals.contains { $0.artist == "Clutch" && $0.album == "Pure Rock Fury" })
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(Set(viewModel.completedEntries.map(\.trackID)) == Set(["as-batch-year", "as-ram-1", "as-ram-2"]))
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
        func isBatchTrack(_ track: Track) -> Bool {
            batchTrackIDs.contains(track.id)
        }
        func isPendingAlbumTrack(_ track: Track) -> Bool {
            track.id == "ram-1" || track.id == "ram-2"
        }

        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.additionalEnrichedTracks = [batchTrack]
            options.idMapper = idMapper
            options.resolveIncrementalTracks = { tracks, _ in
                tracks.filter(isBatchTrack)
            }
            options.runMaintenancePreflight = { pendingDuePreflight() }
            options.prepareMutationMetadata = { tracks in
                await recorder.record(tracks)
                guard tracks.contains(where: isPendingAlbumTrack) else {
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
        #expect(Set(preparedTrackIDBatches.first ?? []) == Set(["batch-year", "ram-1", "ram-2"]))
        if preparedTrackIDBatches.count > 1 {
            #expect(Set(preparedTrackIDBatches[1]) == Set(["ram-1", "ram-2"]))
        }
        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1", "as-ram-2", "as-batch-year"])
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
    }

    @Test("reviewed dry run skips maintenance while resolving the analyzed pending album")
    func dryRunSkipsMaintenance() async throws {
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

        viewModel.start(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.map { "\($0.artist)|\($0.album)" } == ["Daft Punk|Random Access Memories"])
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

    @Test("does not auto verify pending albums during smart-filter live review")
    func doesNotAutoVerifyPendingAlbumsDuringSmartFilterLiveReview() async throws {
        // Live review paths outside the full-library batch must never
        // auto-verify due pending albums — the exclusion is keyed to the
        // batch path, not to previewOnly.
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let fixture = makeRandomAccessWorkflowFixture(pendingVerificationService: pendingVerification) { options in
            options.runMaintenancePreflight = { pendingDuePreflight() }
        }
        let viewModel = fixture.viewModel
        viewModel.mode = .smartFilter
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

        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1"])
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.map(\.trackID) == ["as-ram-1"])
        #expect(viewModel.result?.failedTrackIDs == ["ram-2"])
        #expect(viewModel.failedTracks.contains { $0.id == "ram-2" })
        #expect(viewModel.failedCount == 1)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 0)
    }

    @Test("confirmed no-year preflight defers and continues live batch")
    func deferredContinuesBatch() async throws {
        let run = makeRandomAccessLiveBatchRun(apiYear: nil)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await run.pendingVerification.getAllPendingAlbums().isEmpty == false)
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(await run.timestampUpdates.count() == 1)
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
    }

    @Test("unavailable pending lookup preserves retry window and continues live batch")
    func unavailableContinuesBatch() async throws {
        let run = makeRandomAccessLiveBatchRun(isLookupAvailable: false)
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await run.pendingVerification.getAllPendingAlbums().isEmpty == false)
        #expect(await run.pendingVerification.verificationTimestampUpdateCount() == 0)
        #expect(await run.timestampUpdates.count() == 1)
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
    }

    @Test("mixed resolved and deferred preflight advances the maintenance window")
    func safeOutcomesAdvance() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry(), pureRockFuryPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry(), pureRockFuryPendingEntry()]
        )
        let apiService = PendingYearService(yearsByAlbum: ["Pure Rock Fury": 2001])
        let apiServices = APIOrchestratorServices(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let run = makeRandomAccessLiveBatchRun(
            pendingVerificationService: pendingVerification,
            apiServices: apiServices
        )
        let viewModel = run.viewModel

        startRandomAccessLiveYearBatch(run)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let remaining = await pendingVerification.getAllPendingAlbums()

        #expect(remaining.map(\.album) == ["Random Access Memories"])
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
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
        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1", "as-ram-2", "as-batch-year"])
        #expect(completedTrackIDs == ["as-ram-1", "as-ram-2", "as-batch-year"])
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
        #expect(writes.map(\.databaseID.rawValue) == ["as-batch-year"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["as-batch-year"])
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

        #expect(viewModel.completedEntries.map(\.trackID) == ["as-ram-1", "as-ram-2"])
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

        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1", "as-ram-2"])
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(viewModel.completedEntries.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.processedCount == 2)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
    }

    private func pendingCleaningTracks(
        trackStatus: String? = nil,
        albumArtist: String? = nil
    ) -> [Track] {
        [
            Track(
                id: "ram-1",
                name: "Get Lucky (Remastered 2013)",
                artist: "Pharrell Williams",
                album: "Random Access Memories",
                trackStatus: trackStatus,
                albumArtist: albumArtist
            ),
            Track(
                id: "ram-2",
                name: "Instant Crush",
                artist: "Julian Casablancas",
                album: "Random Access Memories",
                trackStatus: trackStatus,
                albumArtist: albumArtist
            ),
        ]
    }
}

private actor YearLookupProbe {
    private var invalidations = 0
    private var lookupStates = [Int]()

    func recordInvalidation() {
        invalidations += 1
    }

    func recordLookup() {
        lookupStates.append(invalidations)
    }

    func invalidationCount() -> Int {
        invalidations
    }

    func statesAtLookup() -> [Int] {
        lookupStates
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

private struct PendingYearService: ExternalAPIService {
    let yearsByAlbum: [String: Int]

    func getAlbumYear(
        artist _: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        guard let year = yearsByAlbum[album] else { return YearResult() }
        return YearResult(
            year: year,
            isDefinitive: true,
            confidence: 100,
            yearScores: [year: 100]
        )
    }

    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }
}
