import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("WorkflowDashboardState adapter")
@MainActor
struct WorkflowDashboardStateTests {
    @Test("configure phase exposes empty dashboard state")
    func configurePhaseExposesEmptyDashboardState() {
        let viewModel = makeWorkflowViewModel()

        #expect(viewModel.dashboardState == .empty)
    }

    @Test("review phase exposes proposed and accepted counts")
    func reviewPhaseExposesProposedAndAcceptedCounts() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .review
        viewModel.proposedChanges = [
            makeProposedChange(id: "1", isAccepted: true),
            makeProposedChange(id: "2", isAccepted: false),
            makeProposedChange(id: "3", isAccepted: true),
        ]
        viewModel.failedCount = 1

        let state = viewModel.dashboardState

        #expect(state.proposedChangeCount == 3)
        #expect(state.acceptedChangeCount == 2)
        #expect(state.failedWriteCount == 1)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "review")
    }

    @Test("scanning and applying phases are processing with phase labels")
    func scanningAndApplyingPhasesAreProcessingWithPhaseLabels() {
        let viewModel = makeWorkflowViewModel()
        viewModel.proposedChanges = [
            makeProposedChange(id: "1", isAccepted: true),
            makeProposedChange(id: "2", isAccepted: true),
        ]

        viewModel.phase = .scanning
        let scanningState = viewModel.dashboardState

        #expect(scanningState.proposedChangeCount == 2)
        #expect(scanningState.acceptedChangeCount == 2)
        #expect(scanningState.isProcessing)
        #expect(scanningState.phaseLabel == "scanning")

        viewModel.phase = .applying
        let applyingState = viewModel.dashboardState

        #expect(applyingState.proposedChangeCount == 2)
        #expect(applyingState.acceptedChangeCount == 2)
        #expect(applyingState.isProcessing)
        #expect(applyingState.phaseLabel == "applying")
    }

    @Test("error phase uses failed track statuses when they exceed failed count")
    func errorPhaseUsesFailedTrackStatusesWhenTheyExceedFailedCount() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .error("Write failed")
        viewModel.failedCount = 1
        viewModel.trackStatuses = [
            "1": .failed("AppleScript failed"),
            "2": .failed("Missing track"),
            "3": .done,
        ]

        let state = viewModel.dashboardState

        #expect(state.failedWriteCount == 2)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "error")
    }

    @Test("done phase clears accepted dashboard count")
    func donePhaseClearsAcceptedDashboardCount() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .done
        viewModel.proposedChanges = [
            makeProposedChange(id: "1", isAccepted: true),
            makeProposedChange(id: "2", isAccepted: true),
        ]

        let state = viewModel.dashboardState

        #expect(state.proposedChangeCount == 2)
        #expect(state.acceptedChangeCount == 0)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "done")
    }

    @Test("done phase preserves failed writes from batch result")
    func donePhasePreservesFailedWritesFromBatchResult() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .done
        viewModel.result = BatchUpdateResult(
            entries: [],
            failedTrackIDs: ["1", "2"],
            errorDescriptions: ["First failed", "Second failed"]
        )

        let state = viewModel.dashboardState

        #expect(state.failedWriteCount == 2)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "done")
    }

    @Test("failed count wins when it exceeds failed track statuses")
    func failedCountWinsWhenItExceedsFailedTrackStatuses() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .review
        viewModel.failedCount = 3
        viewModel.trackStatuses = [
            "1": .failed("AppleScript failed"),
            "2": .done,
        ]

        let state = viewModel.dashboardState

        #expect(state.failedWriteCount == 3)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "review")
    }
}

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

        if case .review = viewModel.phase {
            #expect(true)
        } else {
            #expect(Bool(false), "preview-only apply should preserve review phase")
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

@MainActor
private func makeWorkflowViewModel() -> WorkflowViewModel {
    let scriptClient = DashboardStateScriptClient()
    let trackStore = DashboardStateTrackStore()
    let cache = DashboardStateCacheService()
    let apiService = DashboardStateAPIService()
    let apiOrchestrator = APIOrchestrator(
        musicBrainz: apiService,
        discogs: apiService,
        appleMusic: apiService,
        cache: cache
    )
    let undoCoordinator = UndoCoordinator(scriptBridge: scriptClient, directory: temporaryDirectory())
    let updateCoordinator = UpdateCoordinator(
        apiOrchestrator: apiOrchestrator,
        scriptBridge: scriptClient,
        trackStore: trackStore,
        cache: cache,
        undoCoordinator: undoCoordinator,
        genreDeterminator: GenreDeterminator()
    )
    let featureGate = FeatureGate(fixedTier: .pro)
    let batchProcessor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: temporaryDirectory()),
        featureGate: featureGate
    )

    return WorkflowViewModel(
        updateCoordinator: updateCoordinator,
        batchProcessor: batchProcessor,
        changePreviewPipeline: ChangePreviewPipeline(),
        featureGate: featureGate
    )
}

private func makeProposedChange(id: String, isAccepted: Bool) -> ProposedChange {
    ProposedChange(
        track: Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album"),
        changeType: .genreUpdate,
        oldValue: nil,
        newValue: "Rock",
        confidence: 90,
        source: "test",
        isAccepted: isAccepted
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GenreUpdaterWorkflowDashboardStateTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private struct DashboardStateAPIService: ExternalAPIService {
    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {}

    func close() async {}
}

private actor DashboardStateScriptClient: AppleScriptClient {
    func initialize() async throws {}

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize _: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        trackIDs.map { Track(id: $0, name: "Track \($0)", artist: "Artist", album: "Album") }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        []
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws {}
}

private actor DashboardStateTrackStore: TrackStateStore {
    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        []
    }

    func saveTracks(_: [Track]) async throws {}

    func deleteTrackIDs(_: [String]) async throws -> Int {
        0
    }

    func getTrack(byID _: String) async throws -> Track? {
        nil
    }

    func updateTrackProcessingState(
        id _: String,
        genreUpdated _: Bool?,
        yearUpdated _: Bool?
    ) async throws {}

    func getUnprocessedTracks() async throws -> [Track] {
        []
    }

    func trackCount() async throws -> Int {
        0
    }
}

private actor DashboardStateCacheService: CacheService {
    func initialize() async throws {}

    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }

    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {}

    func invalidate(key _: String) async {}

    func clear() async {}

    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }

    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {}

    func invalidateAlbum(artist _: String, album _: String) async {}

    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }

    func setCachedAPIResult(_: CachedAPIResult) async {}

    func syncToDisk() async throws {}
}
