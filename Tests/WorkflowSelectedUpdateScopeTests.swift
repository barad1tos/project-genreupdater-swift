import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow selected update scope")
@MainActor
struct WorkflowSelectedUpdateScopeTests {
    @Test("selected scope configuration applies flags and preview counts")
    func selectedScopeConfigurationAppliesFlagsAndPreviewCounts() {
        let viewModel = makeWorkflowViewModel()
        let scopedTracks = [
            Track(id: "1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "2", name: "Two", artist: "Alpha", album: "First"),
        ]

        viewModel.configureSelectedTracksScope(
            tracks: scopedTracks,
            updateGenre: true,
            updateYear: false,
            previewOnly: true
        )

        #expect(viewModel.mode == .selectedTracks)
        #expect(viewModel.updateGenre)
        #expect(!viewModel.updateYear)
        #expect(viewModel.previewOnly)
        #expect(viewModel.scopeTrackCount == 2)
        #expect(viewModel.scopeArtistCount == 1)
    }

    @Test("empty selected scope stays empty instead of becoming full library")
    func emptySelectedScopeStaysEmptyInsteadOfBecomingFullLibrary() {
        let viewModel = makeWorkflowViewModel()

        viewModel.configureSelectedTracksScope(
            tracks: [],
            updateGenre: true,
            updateYear: true,
            previewOnly: false
        )

        #expect(viewModel.mode == .selectedTracks)
        #expect(viewModel.scopeTrackCount == 0)
        #expect(viewModel.scopeArtistCount == 0)
    }

    @Test("preview only apply is ignored")
    func previewOnlyApplyIsIgnored() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .review
        viewModel.previewOnly = true
        viewModel.proposedChanges = [makeProposedChange(id: "1", isAccepted: true)]

        viewModel.applyAccepted()

        guard case .review = viewModel.phase else {
            #expect(Bool(false), "preview-only apply should preserve review phase")
            return
        }
        #expect(viewModel.result == nil)
    }

    @Test("full library preview only avoids batch writes")
    func fullLibraryPreviewOnlyAvoidsBatchWrites() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true

        #expect(!viewModel.shouldRunBatchProcessing)

        viewModel.previewOnly = false

        #expect(viewModel.shouldRunBatchProcessing)
    }

    @Test("full library preview only start uses dry run path")
    func fullLibraryPreviewOnlyStartUsesDryRunPath() async throws {
        let fixture = makeWorkflowFixture(apiService: DashboardStateAPIService(year: 2020, confidence: 90))
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .review = viewModel.phase else {
            #expect(Bool(false), "preview-only full-library start should enter review instead of writing")
            return
        }
        #expect(viewModel.dryRunReport != nil)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library preview only still requires batch feature")
    func fullLibraryPreviewOnlyStillRequiresBatchFeature() async {
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2020, confidence: 90),
            tier: .free
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true

        viewModel.start(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First", year: 1999),
        ])

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "free tier full-library preview should stop at feature gate")
            return
        }
        #expect(message.contains("batchProcessing"))
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library live processing uses album context for genre updates")
    func fullLibraryLiveProcessingUsesAlbumContextForGenreUpdates() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false
        let albumGenreSourceDate = Date(timeIntervalSince1970: 1000)
        let missingGenreDate = Date(timeIntervalSince1970: 2000)

        viewModel.start(tracks: [
            Track(
                id: "missing-genre",
                name: "Only for the Weak",
                artist: "In Flames",
                album: "Clayman",
                dateAdded: missingGenreDate
            ),
            Track(
                id: "genre-source",
                name: "Bullet Ride",
                artist: "In Flames",
                album: "Clayman",
                genre: "Melodic Death Metal",
                dateAdded: albumGenreSourceDate
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "live full-library processing should complete")
            return
        }
        let writes = await fixture.scriptClient.updatedProperties()
        #expect(writes.contains {
            $0.trackID == "missing-genre"
                && $0.property == "genre"
                && $0.value == "Melodic Death Metal"
        })
    }

    @Test("full library live processing surfaces write failures")
    func fullLibraryLiveProcessingSurfacesWriteFailures() async throws {
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2020, confidence: 90),
            failingWriteTrackIDs: ["missing-year"]
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false

        viewModel.start(tracks: [
            Track(id: "missing-year", name: "Track", artist: "In Flames", album: "Clayman", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(!viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedTracks.first?.id == "missing-year")
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library empty effective scope is not runnable")
    func fullLibraryEmptyEffectiveScopeIsNotRunnable() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.configureFullLibraryScope(tracks: [])

        #expect(!viewModel.hasRunnableScope)

        viewModel.start(tracks: [])

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "empty full-library scope should surface an error instead of starting")
            return
        }
        #expect(message.contains("No tracks"))
    }

    @Test("pause is ignored outside full-library scanning")
    func pauseIsIgnoredOutsideFullLibraryScanning() async {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .fullLibrary
        viewModel.phase = .applying

        await viewModel.pause()

        guard case .applying = viewModel.phase else {
            #expect(Bool(false), "pause should not move apply-accepted work into paused state")
            return
        }
    }

    @Test("full library scope resets finished workflow state")
    func fullLibraryScopeResetsFinishedWorkflowState() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .selectedTracks
        viewModel.phase = .done
        viewModel.proposedChanges = [makeProposedChange(id: "1", isAccepted: true)]
        viewModel.result = BatchUpdateResult(entries: [], failedTrackIDs: ["1"], errorDescriptions: ["failed"])
        viewModel.trackStatuses = ["1": .done]
        viewModel.scopeTrackCount = 99

        viewModel.configureFullLibraryScope(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "2", name: "Two", artist: "Beta", album: "Second"),
        ])

        guard case .configure = viewModel.phase else {
            #expect(Bool(false), "full-library setup should reset finished workflow phase")
            return
        }
        #expect(viewModel.mode == .fullLibrary)
        #expect(viewModel.proposedChanges.isEmpty)
        #expect(viewModel.result == nil)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(viewModel.scopeTrackCount == 2)
        #expect(viewModel.scopeArtistCount == 2)
    }

    @Test("selected tracks mode requires non-empty scope")
    func selectedTracksModeRequiresNonEmptyScope() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .selectedTracks
        viewModel.scopeTrackCount = 0

        #expect(!viewModel.hasRunnableScope)

        viewModel.scopeTrackCount = 1

        #expect(viewModel.hasRunnableScope)
    }
}
