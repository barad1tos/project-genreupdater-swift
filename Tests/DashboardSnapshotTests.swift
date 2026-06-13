import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("LibraryDashboardSnapshot")
struct DashboardSnapshotTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("builds coverage and issue counts from real tracks")
    func buildsCoverageAndIssueCounts() {
        let tracks = [
            Track(id: "1", name: "Tagged", artist: "A", album: "One", genre: "Rock", year: 2001),
            Track(id: "2", name: "Missing Genre", artist: "A", album: "One", genre: nil, year: 2001),
            Track(id: "3", name: "Missing Year", artist: "B", album: "Two", genre: "Pop", year: nil),
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
        #expect(snapshot.readyUpdateCount == 5)
        #expect(snapshot.consistencyCoverageRatio == 0.25)
        #expect(snapshot.scanState == .ready(lastScanDate: fixedDate))
        #expect(snapshot.writeState == .ready(count: 5, isDryRun: true))
        #expect(snapshot.issues.map(\.title) == ["Missing genres", "Missing years", "Protected files", "Write errors"])
        #expect(snapshot.issues.map(\.count) == [2, 2, 1, 0])
        #expect(snapshot.issues.map(\.severity) == [.warning, .warning, .critical, .info])
        #expect(snapshot.coverageBuckets.map(\.id) == ["genre", "year", "consistency", "editable"])
        #expect(snapshot.coverageBuckets.map(\.ratio) == [0.5, 0.5, 0.25, 0.75])
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
}

extension DashboardSnapshotTests {
    @Test("view model refreshes dashboard snapshot from load and workflow state")
    @MainActor
    func viewModelRefreshesDashboardSnapshotFromLoadAndWorkflowState() {
        let viewModel = DashboardViewModel()
        let tracks = [
            Track(id: "1", name: "Tagged", artist: "A", album: "One", genre: "Rock", year: 2001),
            Track(id: "2", name: "Missing Year", artist: "B", album: "Two", genre: "Pop", year: nil),
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
                Track(id: "1", name: "Song", artist: "Artist", album: "Album", genre: "Rock", year: 2001),
            ],
            isLoadingTracks: false
        )
        updatingViewModel.setError("Music access failed")
        updatingViewModel.refreshFromLive(tracks: [], isLoadingTracks: true, loadError: nil)

        #expect(updatingViewModel.loadingState == .updating)
        #expect(updatingViewModel.snapshot.scanState == .loading)
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
        #expect(!hasPresentDashboardGenre(nil))
        #expect(!hasPresentDashboardGenre(""))
        #expect(!hasPresentDashboardGenre(" \n\t "))
        #expect(hasPresentDashboardGenre(" Rock "))
    }
}

extension DashboardSnapshotTests {
    @Test("health score rewards coverage and penalizes protected or failed writes")
    func healthScoreReflectsSafety() {
        let healthy = LibraryDashboardSnapshot.make(
            tracks: [
                Track(id: "1", name: "A", artist: "A", album: "A", genre: "Rock", year: 2001),
                Track(id: "2", name: "B", artist: "B", album: "B", genre: "Pop", year: 2002),
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
                Track(id: "2", name: "B", artist: "B", album: "B", genre: nil, year: nil),
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
                year: 2000 + index
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
