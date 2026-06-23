import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@MainActor
func makeWorkflowViewModel() -> WorkflowViewModel {
    makeWorkflowFixture().viewModel
}

@MainActor
func makeWorkflowFixture(
    apiService: DashboardStateAPIService = DashboardStateAPIService(),
    tier: Tier = .pro,
    failingWriteTrackIDs: Set<String> = [],
    resolveIncrementalTracks: @escaping (
        [Track],
        IncrementalTrackScopeOptions
    ) async -> [Track] = { tracks, _ in tracks },
    pendingVerificationService: (any PendingVerificationService)? = nil,
    invalidateAlbumYearCache: (() async -> Void)? = nil,
    updateIncrementalRunTimestamp: (() async -> Void)? = nil
) -> WorkflowFixture {
    let scriptClient = DashboardStateScriptClient(failingTrackIDs: failingWriteTrackIDs)
    let trackStore = DashboardStateTrackStore()
    let cache = DashboardStateCacheService()
    var apiOrchestratorConfiguration = APIOrchestratorConfiguration()
    apiOrchestratorConfiguration.cache = cache
    let apiOrchestrator = APIOrchestrator(
        services: APIOrchestratorServices(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        ),
        configuration: apiOrchestratorConfiguration
    )
    let undoCoordinator = UndoCoordinator(scriptBridge: scriptClient, directory: temporaryDirectory())
    let updateCoordinator = UpdateCoordinator(
        dependencies: UpdateCoordinatorDependencies(
            apiOrchestrator: apiOrchestrator,
            scriptBridge: scriptClient,
            trackStore: trackStore,
            cache: cache,
            undoCoordinator: undoCoordinator,
            pendingVerificationService: pendingVerificationService
        ),
        genreDeterminator: GenreDeterminator()
    )
    let featureGate = FeatureGate(fixedTier: tier)
    let batchProcessor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: temporaryDirectory()),
        featureGate: featureGate
    )

    let viewModel = WorkflowViewModel(
        dependencies: WorkflowViewModel.Dependencies(
            updateCoordinator: updateCoordinator,
            batchProcessor: batchProcessor,
            changePreviewPipeline: ChangePreviewPipeline(),
            pendingVerificationService: pendingVerificationService,
            featureGate: featureGate,
            resolveIncrementalTracks: resolveIncrementalTracks,
            invalidateAlbumYearCache: invalidateAlbumYearCache,
            updateIncrementalRunTimestamp: updateIncrementalRunTimestamp
        )
    )

    return WorkflowFixture(viewModel: viewModel, scriptClient: scriptClient)
}

struct WorkflowFixture {
    let viewModel: WorkflowViewModel
    let scriptClient: DashboardStateScriptClient
}

@MainActor
func waitForWorkflowToLeaveScanning(_ viewModel: WorkflowViewModel) async throws {
    for _ in 0 ..< 200 {
        switch viewModel.phase {
        case .configure, .scanning:
            try await Task.sleep(for: .milliseconds(10))
        case .review, .applying, .done, .paused, .error:
            return
        }
    }

    #expect(Bool(false), "workflow did not leave scanning before timeout")
}

func makeProposedChange(id: String, isAccepted: Bool) -> ProposedChange {
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

struct DashboardStateAPIService: ExternalAPIService {
    let year: Int?
    let confidence: Int
    let beforeAlbumYearLookup: (@Sendable () async -> Void)?

    init(
        year: Int? = nil,
        confidence: Int = 0,
        beforeAlbumYearLookup: (@Sendable () async -> Void)? = nil
    ) {
        self.year = year
        self.confidence = confidence
        self.beforeAlbumYearLookup = beforeAlbumYearLookup
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await beforeAlbumYearLookup?()
        return YearResult(
            year: year,
            confidence: confidence,
            yearScores: year.map { [$0: confidence] } ?? [:]
        )
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

    func initialize(force _: Bool) async throws {
        // Test double has no external resources to initialize.
    }

    func close() async {
        // Test double has no external resources to release.
    }
}

actor DashboardStateScriptClient: AppleScriptClient {
    private let failingTrackIDs: Set<String>
    private var writes: [(trackID: String, property: String, value: String)] = []

    init(failingTrackIDs: Set<String> = []) {
        self.failingTrackIDs = failingTrackIDs
    }

    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

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

    func updateTrackProperty(trackID: String, property: String, value: String) async throws -> AppleScriptWriteResult {
        if failingTrackIDs.contains(trackID) {
            throw DashboardStateScriptWriteError(trackID: trackID)
        }
        writes.append((trackID: trackID, property: property, value: value))
        return .changed
    }

    func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        for update in updates {
            _ = try await updateTrackProperty(
                trackID: update.trackID,
                property: update.property,
                value: update.value
            )
        }
    }

    func updatedProperties() -> [(trackID: String, property: String, value: String)] {
        writes
    }
}

private struct DashboardStateScriptWriteError: LocalizedError {
    let trackID: String

    var errorDescription: String? {
        "script write failed for \(trackID)"
    }
}

private actor DashboardStateTrackStore: TrackStateStore {
    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func loadAllTracks() async throws -> [Track] {
        []
    }

    func saveTracks(_: [Track]) async throws {
        // These tests do not assert persisted track state.
    }

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
    ) async throws {
        // These tests do not assert processing-state persistence.
    }

    func getUnprocessedTracks() async throws -> [Track] {
        []
    }

    func trackCount() async throws -> Int {
        0
    }
}

actor WorkflowPendingVerificationService: PendingVerificationService {
    private let entries: [PendingAlbumEntry]
    private var removals: [(artist: String, album: String)] = []
    private var timestampUpdates = 0

    init(entries: [PendingAlbumEntry]) {
        self.entries = entries
    }

    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func markForVerification(
        artist _: String,
        album _: String,
        reason _: String,
        metadata _: [String: String]?,
        recheckDays _: Int?
    ) async {
        // These tests seed pending entries directly.
    }

    func removeFromPending(artist: String, album: String) async {
        removals.append((artist: artist, album: album))
    }

    func getEntry(artist: String, album: String) async -> PendingAlbumEntry? {
        entries.first { $0.artist == artist && $0.album == album }
    }

    func getAttemptCount(artist: String, album: String) async -> Int {
        await getEntry(artist: artist, album: album)?.attemptCount ?? 0
    }

    func isVerificationNeeded(artist: String, album: String) async -> Bool {
        await getEntry(artist: artist, album: album) != nil
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        entries
    }

    func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        (entries, entries)
    }

    func getProblematicPendingAlbums(minAttempts _: Int) async -> [ProblematicPendingAlbum] {
        []
    }

    func generateProblematicAlbumsReport(minAttempts _: Int, reportURL _: URL?) async throws -> Int {
        0
    }

    func shouldAutoVerify() async -> Bool {
        true
    }

    func updateVerificationTimestamp() async throws {
        timestampUpdates += 1
    }

    func removedAlbums() -> [(artist: String, album: String)] {
        removals
    }

    func verificationTimestampUpdateCount() -> Int {
        timestampUpdates
    }
}

private actor DashboardStateCacheService: CacheService {
    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }

    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {
        // These tests do not assert generic cache writes.
    }

    func invalidate(key _: String) async {
        // These tests do not assert generic cache invalidation.
    }

    func clear() async {
        // These tests do not assert cache clearing.
    }

    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }

    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {
        // These tests read album-year results from the API service stub.
    }

    func invalidateAlbum(artist _: String, album _: String) async {
        // These tests do not assert album cache invalidation.
    }

    func invalidateAllAlbumYears() async {
        // These tests do not assert album cache invalidation.
    }

    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }

    func setCachedAPIResult(_: CachedAPIResult) async {
        // These tests do not assert API-result cache writes.
    }

    func invalidateCachedAPIResults(artist _: String, album _: String) async {
        // These tests do not assert API-result cache invalidation.
    }

    func syncToDisk() async throws {
        // Test double has no disk-backed cache to synchronize.
    }
}
