import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Library dashboard health")
struct DashboardHealthTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("health score rewards coverage and penalizes protected or failed writes")
    func healthReflectsRisk() {
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
    func detectsBlankGenre() {
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
    func capsWritePenalty() {
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
