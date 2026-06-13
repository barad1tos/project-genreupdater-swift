import Core
import Foundation
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
