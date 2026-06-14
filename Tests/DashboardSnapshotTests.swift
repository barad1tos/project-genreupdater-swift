import Core
import Foundation
import Services
import SwiftData
import Testing
@testable import Genre_Updater

@Suite("LibraryDashboardSnapshot")
struct DashboardSnapshotTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("builds coverage and issue counts from real tracks")
    func buildsCoverageAndIssueCounts() {
        let tracks = [
            Track(
                id: "1",
                name: "Tagged",
                artist: "A",
                album: "One",
                genre: "Rock",
                year: 2001,
                trackStatus: "purchased"
            ),
            Track(
                id: "2",
                name: "Missing Genre",
                artist: "A",
                album: "One",
                genre: nil,
                year: 2001,
                trackStatus: "matched"
            ),
            Track(
                id: "3",
                name: "Missing Year",
                artist: "B",
                album: "Two",
                genre: "Pop",
                year: nil,
                trackStatus: "uploaded"
            ),
            Track(
                id: "4",
                name: "Protected",
                artist: "C",
                album: "Three",
                genre: nil,
                year: nil,
                trackStatus: "prerelease"
            ),
        ]

        let snapshot = LibraryDashboardSnapshot.make(
            tracks: tracks,
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: WorkflowDashboardState(
                proposedChangeCount: 7,
                acceptedChangeCount: 5,
                failedWriteCount: 0,
                isProcessing: false,
                phaseLabel: "review"
            )
        )

        #expect(snapshot.totalTracks == 4)
        #expect(snapshot.tracksWithGenre == 2)
        #expect(snapshot.tracksWithYear == 2)
        #expect(snapshot.tracksWithBoth == 1)
        #expect(snapshot.missingGenreCount == 2)
        #expect(snapshot.missingYearCount == 2)
        #expect(snapshot.protectedFileCount == 1)
        #expect(snapshot.isProtectedFileCountKnown)
        #expect(snapshot.readyUpdateCount == 5)
        #expect(snapshot.consistencyCoverageRatio == 0.25)
        #expect(snapshot.allowsReviewActions)
        #expect(snapshot.scanState == .ready(lastScanDate: fixedDate))
        #expect(snapshot.writeState == .ready(count: 5, isDryRun: true))
        #expect(snapshot.issues.map(\.title) == ["Missing genres", "Missing years", "Protected files", "Write errors"])
        #expect(snapshot.issues.map(\.count) == [2, 2, 1, 0])
        #expect(snapshot.issues.map(\.severity) == [.warning, .warning, .critical, .info])
        #expect(snapshot.coverageBuckets.map(\.id) == ["genre", "year", "consistency", "editable"])
        #expect(snapshot.coverageBuckets.map(\.ratio) == [0.5, 0.5, 0.25, 0.75])
    }

    @Test("tracks without editability evidence keep protected-file coverage unknown")
    func tracksWithoutEditabilityEvidenceKeepProtectedFileCoverageUnknown() {
        let snapshot = LibraryDashboardSnapshot.make(
            tracks: [
                Track(id: "1", name: "MusicKit", artist: "A", album: "One", genre: "Rock", year: 2001),
            ],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )

        #expect(!snapshot.isProtectedFileCountKnown)
        #expect(snapshot.protectedFileCount == 0)
        #expect(snapshot.editableCoverageRatio == 0)
        #expect(snapshot.coverageBuckets.first { $0.id == "editable" }?.title == "Editable files unknown")
        #expect(snapshot.issues.first { $0.id == "protected-files" }?.title == "Protected files unknown")
        #expect(snapshot.issues.first { $0.id == "protected-files" }?.severity == .warning)
    }

    @Test("does not fake ready updates when workflow has no proposed changes")
    func emptyWorkflowKeepsReadyUpdatesAtZero() {
        let snapshot = LibraryDashboardSnapshot.make(
            tracks: [Track(id: "1", name: "Song", artist: "A", album: "Album", genre: "Rock", year: 2000)],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )

        #expect(snapshot.readyUpdateCount == 0)
        #expect(snapshot.writeState == .dryRun)
        #expect(snapshot.primaryActionTitle == "Review changes")
    }

    @Test("explicit load error wins over empty-library interpretation")
    func explicitLoadErrorWinsOverEmptyLibrary() {
        let snapshot = LibraryDashboardSnapshot.make(
            tracks: [],
            lastScanDate: nil,
            isLoading: false,
            loadError: .failed("Music access failed"),
            isDryRun: true,
            workflow: .empty
        )

        #expect(snapshot.scanState == .failed("Music access failed"))
        #expect(snapshot.totalTracks == 0)
        #expect(snapshot.healthScore == 0)
        #expect(snapshot.primaryStatusText == "Music access failed")
    }

    @Test("cached metrics keep protected-file coverage unknown when the cache cannot prove it")
    func cachedMetricsKeepProtectedFileCoverageUnknown() {
        let cachedMetrics = PersistedMetricsSnapshot(
            totalTracks: 3,
            tracksWithGenre: 3,
            tracksWithYear: 3,
            tracksWithBoth: 3,
            tracksNeedingGenre: 0,
            tracksNeedingYear: 0,
            recentlyAdded: 0,
            timestamp: fixedDate
        )

        let snapshot = LibraryDashboardSnapshot.make(
            persistedMetrics: cachedMetrics,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )

        #expect(!snapshot.isProtectedFileCountKnown)
        #expect(snapshot.protectedFileCount == 0)
        #expect(snapshot.editableCoverageRatio == 0)
        #expect(snapshot.coverageBuckets.first { $0.id == "editable" }?.title == "Editable files unknown")
        #expect(snapshot.issues.first { $0.id == "protected-files" }?.title == "Protected files unknown")
        #expect(snapshot.issues.first { $0.id == "protected-files" }?.severity == .warning)
    }

    @Test("cached metrics use persisted protected-file count when present")
    func cachedMetricsUsePersistedProtectedFileCount() {
        let cachedMetrics = PersistedMetricsSnapshot(
            totalTracks: 4,
            tracksWithGenre: 4,
            tracksWithYear: 4,
            tracksWithBoth: 4,
            tracksNeedingGenre: 0,
            tracksNeedingYear: 0,
            protectedFileCount: 1,
            recentlyAdded: 0,
            timestamp: fixedDate
        )

        let snapshot = LibraryDashboardSnapshot.make(
            persistedMetrics: cachedMetrics,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )

        #expect(snapshot.isProtectedFileCountKnown)
        #expect(snapshot.protectedFileCount == 1)
        #expect(snapshot.editableCoverageRatio == 0.75)
        #expect(snapshot.coverageBuckets.first { $0.id == "editable" }?.title == "Editable files")
        #expect(snapshot.issues.first { $0.id == "protected-files" }?.severity == .critical)
    }

    @Test("review actions require ready scan and non-writing state")
    func reviewActionsRequireReadyScanAndNonWritingState() {
        let readyTrack = Track(
            id: "1",
            name: "Song",
            artist: "A",
            album: "Album",
            genre: "Rock",
            year: 2000,
            trackStatus: "purchased"
        )
        let ready = LibraryDashboardSnapshot.make(
            tracks: [readyTrack],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )
        let loading = LibraryDashboardSnapshot.make(
            tracks: [],
            lastScanDate: nil,
            isLoading: true,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )
        let failed = LibraryDashboardSnapshot.make(
            tracks: [readyTrack],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: .failed("Music access failed"),
            isDryRun: true,
            workflow: .empty
        )
        let empty = LibraryDashboardSnapshot.make(
            tracks: [],
            lastScanDate: nil,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )
        let writing = LibraryDashboardSnapshot.make(
            tracks: [readyTrack],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: WorkflowDashboardState(
                proposedChangeCount: 1,
                acceptedChangeCount: 1,
                failedWriteCount: 0,
                isProcessing: true,
                phaseLabel: "Writing"
            )
        )

        #expect(ready.allowsReviewActions)
        #expect(!loading.allowsReviewActions)
        #expect(!failed.allowsReviewActions)
        #expect(!empty.allowsReviewActions)
        #expect(!writing.allowsReviewActions)
    }
}

extension DashboardSnapshotTests {
    @Test("view model refreshes dashboard snapshot from load and workflow state")
    @MainActor
    func viewModelRefreshesDashboardSnapshotFromLoadAndWorkflowState() {
        let viewModel = DashboardViewModel()
        let tracks = [
            Track(
                id: "1",
                name: "Tagged",
                artist: "A",
                album: "One",
                genre: "Rock",
                year: 2001,
                trackStatus: "purchased"
            ),
            Track(
                id: "2",
                name: "Missing Year",
                artist: "B",
                album: "Two",
                genre: "Pop",
                year: nil,
                trackStatus: "matched"
            ),
        ]
        let workflow = WorkflowDashboardState(
            proposedChangeCount: 3,
            acceptedChangeCount: 2,
            failedWriteCount: 1,
            isProcessing: false,
            phaseLabel: "review"
        )

        viewModel.refreshSnapshot(
            tracks: tracks,
            lastScanDate: fixedDate,
            isLoadingTracks: false,
            loadError: nil,
            isDryRun: false,
            workflowState: workflow
        )

        #expect(viewModel.snapshot.totalTracks == 2)
        #expect(viewModel.snapshot.scanState == .ready(lastScanDate: fixedDate))
        #expect(viewModel.snapshot.writeState == .blocked("1 write errors"))
        #expect(viewModel.snapshot.readyUpdateCount == 2)
        #expect(viewModel.snapshot.issues.last?.count == 1)

        viewModel.setError("Music access failed")
        #expect(viewModel.snapshot.scanState == .failed("Music access failed"))
        #expect(viewModel.snapshot.primaryActionTitle == "Retry scan")

        viewModel.setPermissionDenied()
        #expect(viewModel.snapshot.scanState == .permissionDenied)
        #expect(viewModel.snapshot.primaryActionTitle == "Grant access")
    }

    @Test("cached tracks remain visible while live load error drives scan state")
    @MainActor
    func cachedTracksRemainVisibleWhileLiveLoadErrorDrivesScanState() {
        let viewModel = DashboardViewModel()
        let cachedTracks = [
            Track(
                id: "1",
                name: "Cached",
                artist: "A",
                album: "One",
                genre: "Rock",
                year: 2001,
                trackStatus: "purchased"
            ),
        ]

        viewModel.refreshSnapshot(
            tracks: cachedTracks,
            lastScanDate: fixedDate,
            isLoadingTracks: false,
            loadError: .failed("Music access failed"),
            isDryRun: true,
            workflowState: .empty
        )

        #expect(viewModel.snapshot.totalTracks == 1)
        #expect(viewModel.snapshot.scanState == .failed("Music access failed"))
        #expect(!viewModel.snapshot.allowsReviewActions)
        #expect(viewModel.snapshot.primaryActionTitle == "Retry scan")
    }

    @Test("cached metrics refresh dashboard snapshot during warm loading")
    @MainActor
    func cachedMetricsRefreshDashboardSnapshotDuringWarmLoading() {
        let cachedMetrics = PersistedMetricsSnapshot(
            totalTracks: 12,
            tracksWithGenre: 9,
            tracksWithYear: 10,
            tracksWithBoth: 8,
            tracksNeedingGenre: 3,
            tracksNeedingYear: 2,
            recentlyAdded: 1,
            timestamp: fixedDate
        )
        let workflow = WorkflowDashboardState(
            proposedChangeCount: 4,
            acceptedChangeCount: 2,
            failedWriteCount: 0,
            isProcessing: false,
            phaseLabel: "Review"
        )
        let viewModel = DashboardViewModel()
        viewModel.refreshSnapshot(
            tracks: [],
            metricsSnapshot: cachedMetrics,
            lastScanDate: nil,
            isLoadingTracks: true,
            loadError: nil,
            isDryRun: false,
            workflowState: workflow
        )
        #expect(viewModel.snapshot.totalTracks == 12)
        #expect(viewModel.snapshot.scanState == .loading)
        #expect(viewModel.snapshot.writeState == .ready(count: 2, isDryRun: false))
        #expect(viewModel.showShimmer == false)
        #expect(viewModel.loadingState == .cached(lastUpdated: fixedDate))
        #expect(viewModel.snapshot.primaryActionTitle == "Scanning...")

        viewModel.refreshSnapshot(
            tracks: [],
            metricsSnapshot: cachedMetrics,
            lastScanDate: nil,
            isLoadingTracks: false,
            loadError: nil,
            isDryRun: false,
            workflowState: workflow
        )
        #expect((viewModel.snapshot.totalTracks, viewModel.snapshot.scanState) == (0, .empty))
        #expect(viewModel.loadingState == .emptyLibrary)
    }

    @Test("refresh snapshot keeps load error ahead of loading and write state")
    @MainActor
    func refreshSnapshotKeepsLoadErrorAheadOfLoadingAndWriteState() {
        let viewModel = DashboardViewModel()
        let writingWorkflow = WorkflowDashboardState(
            proposedChangeCount: 2,
            acceptedChangeCount: 2,
            failedWriteCount: 0,
            isProcessing: true,
            phaseLabel: "writing"
        )

        viewModel.refreshSnapshot(
            tracks: [],
            lastScanDate: nil,
            isLoadingTracks: true,
            loadError: .failed("Music access failed"),
            isDryRun: false,
            workflowState: writingWorkflow
        )

        #expect(viewModel.loadingState == .error("Music access failed"))
        #expect(viewModel.snapshot.scanState == .failed("Music access failed"))
        #expect(viewModel.snapshot.writeState == .writing(label: "writing"))
        #expect(viewModel.snapshot.primaryActionTitle == "Retry scan")

        let blockedWorkflow = WorkflowDashboardState(
            proposedChangeCount: 2,
            acceptedChangeCount: 1,
            failedWriteCount: 1,
            isProcessing: false,
            phaseLabel: "review"
        )

        viewModel.refreshSnapshot(
            tracks: [],
            lastScanDate: nil,
            isLoadingTracks: true,
            loadError: .permissionDenied,
            isDryRun: false,
            workflowState: blockedWorkflow
        )

        #expect(viewModel.loadingState == .permissionDenied)
        #expect(viewModel.snapshot.scanState == .permissionDenied)
        #expect(viewModel.snapshot.writeState == .blocked("1 write errors"))
        #expect(viewModel.snapshot.primaryActionTitle == "Grant access")
    }

    @Test("view model load error wins over empty-library state")
    @MainActor
    func viewModelLoadErrorWinsOverEmptyLibraryState() {
        let viewModel = DashboardViewModel()

        viewModel.refreshFromLive(
            tracks: [],
            isLoadingTracks: false,
            loadError: .failed("Music access failed")
        )

        #expect(viewModel.loadingState == .error("Music access failed"))
        #expect(viewModel.snapshot.scanState == .failed("Music access failed"))

        viewModel.refreshFromLive(
            tracks: [],
            isLoadingTracks: false,
            loadError: .permissionDenied
        )

        #expect(viewModel.loadingState == .permissionDenied)
        #expect(viewModel.snapshot.scanState == .permissionDenied)
    }

    @Test("restricted access is not treated as grantable permission")
    @MainActor
    func restrictedAccessIsNotTreatedAsGrantablePermission() {
        let viewModel = DashboardViewModel()

        viewModel.refreshFromLive(
            tracks: [],
            isLoadingTracks: false,
            loadError: .restricted
        )

        #expect(viewModel.loadingState == .error(LibraryLoadError.restricted.message))
        #expect(viewModel.snapshot.scanState == .failed(LibraryLoadError.restricted.message))
        #expect(viewModel.snapshot.primaryActionTitle == "Retry scan")
    }

    @Test("retry loading clears stale load errors")
    @MainActor
    func retryLoadingClearsStaleLoadErrors() {
        let failedViewModel = DashboardViewModel()

        failedViewModel.setError("Music access failed")
        failedViewModel.refreshFromLive(tracks: [], isLoadingTracks: true, loadError: nil)

        #expect(failedViewModel.loadingState == .shimmer)
        #expect(failedViewModel.snapshot.scanState == .loading)

        failedViewModel.refreshSnapshot(
            tracks: [],
            lastScanDate: nil,
            isLoadingTracks: true,
            loadError: nil,
            isDryRun: true,
            workflowState: .empty
        )

        #expect(failedViewModel.loadingState == .shimmer)
        #expect(failedViewModel.snapshot.scanState == .loading)

        let deniedViewModel = DashboardViewModel()

        deniedViewModel.setPermissionDenied()
        deniedViewModel.refreshFromLive(tracks: [], isLoadingTracks: true, loadError: nil)

        #expect(deniedViewModel.loadingState == .shimmer)
        #expect(deniedViewModel.snapshot.scanState == .loading)

        let updatingViewModel = DashboardViewModel()

        updatingViewModel.refreshFromLive(
            tracks: [
                Track(
                    id: "1",
                    name: "Song",
                    artist: "Artist",
                    album: "Album",
                    genre: "Rock",
                    year: 2001,
                    trackStatus: "purchased"
                ),
            ],
            isLoadingTracks: false
        )
        updatingViewModel.setError("Music access failed")
        updatingViewModel.refreshFromLive(tracks: [], isLoadingTracks: true, loadError: nil)

        #expect(updatingViewModel.loadingState == .updating)
        #expect(updatingViewModel.snapshot.scanState == .loading)
    }

    @Test("cancelled loading timeout does not fail a restarted shimmer")
    @MainActor
    func cancelledLoadingTimeoutDoesNotFailRestartedShimmer() async {
        let viewModel = DashboardViewModel()

        viewModel.loadCachedMetrics(from: nil)
        viewModel.loadCachedMetrics(from: nil)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(viewModel.loadingState == .shimmer)
    }

    @Test("warm cached loading times out when live refresh stalls")
    @MainActor
    func warmCachedLoadingTimesOutWhenLiveRefreshStalls() async {
        let cachedMetrics = PersistedMetricsSnapshot(
            totalTracks: 12,
            tracksWithGenre: 9,
            tracksWithYear: 10,
            tracksWithBoth: 8,
            tracksNeedingGenre: 3,
            tracksNeedingYear: 2,
            recentlyAdded: 1,
            timestamp: fixedDate
        )
        let viewModel = DashboardViewModel(loadingTimeoutDuration: .milliseconds(10))

        viewModel.refreshSnapshot(
            tracks: [],
            metricsSnapshot: cachedMetrics,
            lastScanDate: nil,
            isLoadingTracks: true,
            loadError: nil,
            isDryRun: true,
            workflowState: .empty
        )
        #expect(viewModel.loadingState == .cached(lastUpdated: fixedDate))

        try? await Task.sleep(for: .milliseconds(30))

        #expect(viewModel
            .loadingState == .error("Loading timed out. Please check your Music library access and try again."))
        #expect(viewModel.snapshot.primaryActionTitle == "Retry scan")
    }

    @Test("track content fingerprint changes for same-count dashboard metadata")
    func trackContentFingerprintChangesForSameCountMetadata() {
        let base = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album", genre: nil, year: nil),
        ]
        let tagged = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album", genre: "Rock", year: nil),
        ]
        let taggedWithWhitespace = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album", genre: " Rock\n", year: nil),
        ]
        let yearTagged = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album", genre: nil, year: 2001),
        ]
        let protected = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album", trackStatus: "prerelease"),
        ]
        let recentlyAdded = [
            Track(
                id: "1",
                name: "Song",
                artist: "Artist",
                album: "Album",
                dateAdded: fixedDate
            ),
        ]
        let sameSecondAdded = [
            Track(
                id: "1",
                name: "Song",
                artist: "Artist",
                album: "Album",
                dateAdded: fixedDate.addingTimeInterval(0.25)
            ),
        ]
        let laterAdded = [
            Track(
                id: "1",
                name: "Song",
                artist: "Artist",
                album: "Album",
                dateAdded: fixedDate.addingTimeInterval(10)
            ),
        ]
        let baseFingerprint = DashboardTrackContentFingerprint.make(from: base)
        let taggedFingerprint = DashboardTrackContentFingerprint.make(from: tagged)
        let taggedWithWhitespaceFingerprint = DashboardTrackContentFingerprint.make(from: taggedWithWhitespace)
        let yearTaggedFingerprint = DashboardTrackContentFingerprint.make(from: yearTagged)
        let protectedFingerprint = DashboardTrackContentFingerprint.make(from: protected)
        let recentlyAddedFingerprint = DashboardTrackContentFingerprint.make(from: recentlyAdded)
        let sameSecondAddedFingerprint = DashboardTrackContentFingerprint.make(from: sameSecondAdded)
        let laterAddedFingerprint = DashboardTrackContentFingerprint.make(from: laterAdded)

        #expect(baseFingerprint != taggedFingerprint)
        #expect(taggedFingerprint == taggedWithWhitespaceFingerprint)
        #expect(baseFingerprint != yearTaggedFingerprint)
        #expect(baseFingerprint != protectedFingerprint)
        #expect(baseFingerprint != recentlyAddedFingerprint)
        #expect(recentlyAddedFingerprint != sameSecondAddedFingerprint)
        #expect(recentlyAddedFingerprint != laterAddedFingerprint)
    }

    @Test("view model metrics treat whitespace-only genre as missing")
    @MainActor
    func viewModelMetricsTreatWhitespaceOnlyGenreAsMissing() {
        let viewModel = DashboardViewModel()

        viewModel.refreshFromLive(
            tracks: [
                Track(id: "1", name: "Whitespace", artist: "A", album: "A", genre: "   ", year: 2001),
                Track(id: "2", name: "Tagged", artist: "B", album: "B", genre: "Pop", year: 2002),
            ],
            isLoadingTracks: false
        )

        #expect(viewModel.metrics.tracksWithGenre == 1)
        #expect(viewModel.metrics.tracksNeedingGenre == 1)
        #expect(viewModel.metrics.tracksWithBoth == 1)
        #expect(viewModel.metrics.consistencyCoverage == 0.5)
    }

    @Test("persisted metrics genre helper trims whitespace")
    func persistedMetricsGenreHelperTrimsWhitespace() {
        #expect(!GenreUtilities.hasPresentGenre(nil))
        #expect(!GenreUtilities.hasPresentGenre(""))
        #expect(!GenreUtilities.hasPresentGenre(" \n\t "))
        #expect(GenreUtilities.hasPresentGenre(" Rock "))
    }

    @Test("metrics snapshot persistence writes protected count when editability is known")
    @MainActor
    func metricsSnapshotPersistenceWritesProtectedCountWhenEditabilityIsKnown() throws {
        let context = try ModelContext(ModelContainerFactory.createInMemory())
        let persistedSnapshot = upsertDashboardMetricsSnapshot(
            from: [
                Track(
                    id: "1",
                    name: "Editable",
                    artist: "A",
                    album: "One",
                    genre: "Rock",
                    year: 2001,
                    trackStatus: "purchased"
                ),
                Track(
                    id: "2",
                    name: "Protected",
                    artist: "B",
                    album: "Two",
                    genre: "Pop",
                    year: 2002,
                    trackStatus: "prerelease"
                ),
            ],
            in: context
        )

        #expect(persistedSnapshot?.protectedFileCount == 1)
    }

    @Test("metrics snapshot persistence keeps protected count unknown for MusicKit tracks")
    @MainActor
    func metricsSnapshotPersistenceKeepsProtectedCountUnknownForMusicKitTracks() throws {
        let context = try ModelContext(ModelContainerFactory.createInMemory())
        let persistedSnapshot = upsertDashboardMetricsSnapshot(
            from: [
                Track(id: "1", name: "MusicKit", artist: "A", album: "One", genre: "Rock", year: 2001),
            ],
            in: context
        )

        #expect(persistedSnapshot?.protectedFileCount == nil)
    }
}

extension DashboardSnapshotTests {
    @Test("health score rewards coverage and penalizes protected or failed writes")
    func healthScoreReflectsSafety() {
        let healthy = LibraryDashboardSnapshot.make(
            tracks: [
                Track(
                    id: "1",
                    name: "A",
                    artist: "A",
                    album: "A",
                    genre: "Rock",
                    year: 2001,
                    trackStatus: "purchased"
                ),
                Track(
                    id: "2",
                    name: "B",
                    artist: "B",
                    album: "B",
                    genre: "Pop",
                    year: 2002,
                    trackStatus: "matched"
                ),
            ],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )

        let risky = LibraryDashboardSnapshot.make(
            tracks: [
                Track(id: "1", name: "A", artist: "A", album: "A", genre: nil, year: nil, trackStatus: "prerelease"),
                Track(id: "2", name: "B", artist: "B", album: "B", genre: nil, year: nil, trackStatus: "purchased"),
            ],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: false,
            workflow: WorkflowDashboardState(
                proposedChangeCount: 0,
                acceptedChangeCount: 0,
                failedWriteCount: 1,
                isProcessing: false,
                phaseLabel: "error"
            )
        )

        #expect(healthy.healthScore > risky.healthScore)
        #expect(healthy.healthScore == 1)
        #expect(risky.healthScore < 0.25)
    }

    @Test("whitespace-only genre counts as missing")
    func whitespaceOnlyGenreCountsAsMissing() {
        let snapshot = LibraryDashboardSnapshot.make(
            tracks: [
                Track(id: "1", name: "Whitespace", artist: "A", album: "A", genre: "   ", year: 2001),
                Track(id: "2", name: "Tagged", artist: "B", album: "B", genre: "Pop", year: 2002),
            ],
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: true,
            workflow: .empty
        )

        #expect(snapshot.tracksWithGenre == 1)
        #expect(snapshot.missingGenreCount == 1)
        #expect(snapshot.tracksWithBoth == 1)
        #expect(snapshot.consistencyCoverageRatio == 0.5)
    }

    @Test("failed write penalty scales up to a cap")
    func failedWritePenaltyScalesUpToCap() {
        let tracks = (1 ... 10).map { index in
            Track(
                id: "\(index)",
                name: "Song \(index)",
                artist: "Artist",
                album: "Album",
                genre: "Rock",
                year: 2000 + index,
                trackStatus: "purchased"
            )
        }

        let oneFailure = LibraryDashboardSnapshot.make(
            tracks: tracks,
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: false,
            workflow: WorkflowDashboardState(
                proposedChangeCount: 10,
                acceptedChangeCount: 9,
                failedWriteCount: 1,
                isProcessing: false,
                phaseLabel: "write"
            )
        )

        let manyFailures = LibraryDashboardSnapshot.make(
            tracks: tracks,
            lastScanDate: fixedDate,
            isLoading: false,
            loadError: nil,
            isDryRun: false,
            workflow: WorkflowDashboardState(
                proposedChangeCount: 10,
                acceptedChangeCount: 0,
                failedWriteCount: 10,
                isProcessing: false,
                phaseLabel: "write"
            )
        )

        #expect(oneFailure.healthScore > manyFailures.healthScore)
        #expect(oneFailure.issues.map(\.severity).last == .critical)
        #expect(manyFailures.healthScore == 0.6)
    }
}
