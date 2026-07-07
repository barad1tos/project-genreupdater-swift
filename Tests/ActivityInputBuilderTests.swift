import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityInputBuilder")
struct ActivityInputBuilderTests {
    @Test("permission denied load error maps to permissionDenied library state")
    func mapsPermissionDenied() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            loadError: .permissionDenied,
            isLoading: false
        ))

        #expect(input.libraryState == .permissionDenied(LibraryLoadError.permissionDenied.message))
    }

    @Test("failed load error maps to failed library state")
    func mapsFailedLoad() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            loadError: .failed("Music.app is unavailable"),
            isLoading: false
        ))

        #expect(input.libraryState == .failed("Music.app is unavailable"))
    }

    @Test("loading with no error maps to loading library state")
    func mapsLoadingState() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            loadError: nil,
            isLoading: true
        ))

        #expect(input.libraryState == .loading)
    }

    @Test("no error and not loading maps to empty or ready by track count")
    func mapsTrackCountState() {
        let emptyInput = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [],
            loadError: nil,
            isLoading: false
        ))
        let readyInput = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false
        ))

        #expect(emptyInput.libraryState == .empty)
        #expect(readyInput.libraryState == .ready)
    }

    @Test("fix plan projection maps to activity summary")
    func mapsFixPlanProjection() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false,
            fixPlanProjection: fixPlanProjection()
        ))

        #expect(input.fixPlan == ActivityFixPlanSummary(
            status: .ready,
            itemCount: 4,
            acceptedCount: 3,
            canApply: true
        ))
        #expect(input.proposedFixCount == 4)
        #expect(input.acceptedFixCount == 3)
    }

    private func track(id: String) -> Core.Track {
        Core.Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
    }

    private func makeContext(
        tracks: [Core.Track] = [],
        loadError: LibraryLoadError?,
        isLoading: Bool,
        fixPlanProjection: FixPlanProjection = .empty()
    ) -> ActivityInputContext {
        ActivityInputContext(
            tracks: tracks,
            metricsSnapshot: nil,
            lastScanDate: nil,
            loadError: loadError,
            isLoading: isLoading,
            isDryRun: false,
            workflow: .empty,
            fixPlanProjection: fixPlanProjection,
            pendingVerification: nil,
            runLifecycle: nil,
            isLibrarySyncAvailable: true,
            isAutoSyncRunning: false,
            now: Date(timeIntervalSince1970: 100)
        )
    }

    private func fixPlanProjection() -> FixPlanProjection {
        FixPlanProjection(
            revision: .initial,
            status: .ready,
            lineage: FixPlanProjection.Lineage(
                planID: nil,
                planRevision: nil,
                decisionRevision: nil,
                sourceRunID: nil
            ),
            summary: FixPlanProjection.Summary(
                itemCount: 4,
                acceptedCount: 3,
                rejectedCount: 1,
                genreCount: 3,
                yearCount: 1,
                averageConfidence: 92,
                canApply: true
            ),
            stalenessReasons: [],
            items: [],
            operationalIssues: []
        )
    }
}
