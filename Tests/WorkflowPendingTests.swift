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
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resolvedEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let skippedEntry = PendingAlbumEntry(
            id: "clutch-pure-rock-fury",
            artist: "Clutch",
            album: "Pure Rock Fury",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [resolvedEntry, skippedEntry],
            dueEntries: [resolvedEntry],
            problematicAlbums: [
                ProblematicPendingAlbum(
                    entry: resolvedEntry,
                    totalAttempts: 3,
                    firstAttempt: now,
                    lastAttempt: now,
                    daysSinceFirstAttempt: 14
                ),
            ]
        )
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let removals = await pendingVerification.removedAlbums()
        let remainingPending = await pendingVerification.getAllPendingAlbums()
        let summary = try #require(viewModel.pendingVerificationReportSummary)

        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(remainingPending.map(\.id) == ["clutch-pure-rock-fury"])
        #expect(summary.total == 1)
        #expect(summary.due == 0)
        #expect(summary.problematic == 0)
    }

    @Test("ignores stale pending scope refresh after pending run")
    func ignoresStalePendingScopeRefreshAfterPendingRun() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resolvedEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let skippedEntry = PendingAlbumEntry(
            id: "clutch-pure-rock-fury",
            artist: "Clutch",
            album: "Pure Rock Fury",
            reason: "no_year_found"
        )
        let pendingSnapshotDelay = PendingSnapshotDelay()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [resolvedEntry, skippedEntry],
            dueEntries: [resolvedEntry],
            problematicAlbums: [
                ProblematicPendingAlbum(
                    entry: resolvedEntry,
                    totalAttempts: 3,
                    firstAttempt: now,
                    lastAttempt: now,
                    daysSinceFirstAttempt: 14
                ),
            ],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.computeScopePreview(tracks: randomAccessMemoriesMusicKitTracks())
        await pendingSnapshotDelay.waitForCapturedFirstSnapshot()

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())
        try await waitForWorkflowToLeaveScanning(viewModel)
        let finalSummary = try #require(viewModel.pendingVerificationReportSummary)
        #expect(finalSummary.total == 1)
        #expect(finalSummary.due == 0)
        #expect(finalSummary.problematic == 0)

        await pendingSnapshotDelay.releaseFirstSnapshot()
        await pendingSnapshotDelay.waitForProblematicCountAfterDelayedSnapshot()
        await Task.yield()

        let summary = try #require(viewModel.pendingVerificationReportSummary)
        #expect(summary.total == 1)
        #expect(summary.due == 0)
        #expect(summary.problematic == 0)
    }

    @Test("summarizes pending snapshot facts for update run reports")
    func summarizesPendingSnapshotFactsForUpdateRunReports() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dueEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let problematicEntry = PendingAlbumEntry(
            id: "clutch-pure-rock-fury",
            artist: "Clutch",
            album: "Pure Rock Fury",
            reason: "no_year_found"
        )
        let skippedProblematicEntry = PendingAlbumEntry(
            id: "archive-noise",
            artist: "Archive",
            album: "Noise",
            reason: "no_year_found"
        )
        let pendingSnapshotDelay = PendingSnapshotDelay()
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [dueEntry, problematicEntry, skippedProblematicEntry],
            dueEntries: [dueEntry],
            problematicAlbums: [
                ProblematicPendingAlbum(
                    entry: problematicEntry,
                    totalAttempts: 3,
                    firstAttempt: now,
                    lastAttempt: now,
                    daysSinceFirstAttempt: 14
                ),
                ProblematicPendingAlbum(
                    entry: skippedProblematicEntry,
                    totalAttempts: 4,
                    firstAttempt: now,
                    lastAttempt: now,
                    daysSinceFirstAttempt: 21
                ),
            ],
            pendingSnapshotDelay: pendingSnapshotDelay
        )
        let viewModel = makeWorkflowFixture(pendingVerificationService: pendingVerification).viewModel
        viewModel.mode = .pendingVerification

        viewModel.computeScopePreview(tracks: [])
        await pendingSnapshotDelay.waitForCapturedFirstSnapshot()
        await pendingSnapshotDelay.releaseFirstSnapshot()
        await pendingSnapshotDelay.waitForProblematicCountAfterDelayedSnapshot()
        await Task.yield()

        let summary = try #require(viewModel.pendingVerificationReportSummary)
        #expect(summary.total == 3)
        #expect(summary.due == 1)
        #expect(summary.problematic == 2)

        viewModel.reset()
        #expect(viewModel.pendingVerificationReportSummary == nil)

        viewModel.pendingVerificationReportSummary = summary
        viewModel.mode = .selectedTracks
        viewModel.start(tracks: [])
        #expect(viewModel.pendingVerificationReportSummary == nil)
    }
}
