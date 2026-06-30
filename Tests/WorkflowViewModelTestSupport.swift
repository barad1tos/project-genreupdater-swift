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
    apiServices: APIOrchestratorServices? = nil,
    tier: Tier = .pro,
    failingWriteTrackIDs: Set<String> = [],
    cancellingWriteTrackIDs: Set<String> = [],
    noChangeWriteTrackIDs: Set<String> = [],
    writeHold: LiveBatchHold? = nil,
    resolveIncrementalTracks: @escaping (
        [Track],
        IncrementalTrackScopeOptions
    ) async -> [Track] = { tracks, _ in tracks },
    pendingVerificationService: (any PendingVerificationService)? = nil,
    idMapper: (any TrackIDMapping)? = nil,
    problematicAlbumReportMinAttempts: @escaping () -> Int = { 3 },
    runMaintenancePreflight: (() async -> MaintenancePreflightResult?)? = nil,
    prepareMutationMetadata: (([Track]) async throws -> Void)? = { _ in },
    invalidateAlbumYearCache: (() async -> Void)? = nil,
    updateIncrementalRunTimestamp: (() async -> Void)? = nil
) -> WorkflowFixture {
    let scriptClient = DashboardStateScriptClient(
        failingTrackIDs: failingWriteTrackIDs,
        cancellingTrackIDs: cancellingWriteTrackIDs,
        noChangeTrackIDs: noChangeWriteTrackIDs,
        writeHold: writeHold
    )
    let trackStore = DashboardStateTrackStore()
    let cache = DashboardStateCacheService()
    var apiOrchestratorConfiguration = APIOrchestratorConfiguration()
    apiOrchestratorConfiguration.cache = cache
    let resolvedAPIServices = apiServices ?? APIOrchestratorServices(
        musicBrainz: apiService,
        discogs: apiService,
        appleMusic: apiService
    )
    let apiOrchestrator = APIOrchestrator(
        services: resolvedAPIServices,
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
            idMapper: idMapper,
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
            runMaintenancePreflight: runMaintenancePreflight,
            prepareMutationMetadata: prepareMutationMetadata,
            resolveIncrementalTracks: resolveIncrementalTracks,
            invalidateAlbumYearCache: invalidateAlbumYearCache,
            updateIncrementalRunTimestamp: updateIncrementalRunTimestamp,
            problematicAlbumReportMinAttempts: problematicAlbumReportMinAttempts
        )
    )

    return WorkflowFixture(viewModel: viewModel, scriptClient: scriptClient)
}

struct WorkflowFixture {
    let viewModel: WorkflowViewModel
    let scriptClient: DashboardStateScriptClient
}

actor MutationPreparationRecorder {
    private(set) var preparedTrackIDs: [String] = []
    private var callCount = 0

    func record(_ tracks: [Track]) {
        callCount += 1
        preparedTrackIDs = tracks.map(\.id)
    }

    func recordedCallCount() -> Int {
        callCount
    }
}

actor MutationPreparationHold {
    private var hasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        hasStarted = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
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

@MainActor
func waitForWorkflowToReturnToConfigure(_ viewModel: WorkflowViewModel) async throws {
    for _ in 0 ..< 500 {
        if case .configure = viewModel.phase {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(Bool(false), "workflow did not return to configure before timeout")
}

@MainActor
func computeDelayedPendingScopePreview(
    viewModel: WorkflowViewModel,
    tracks: [Track],
    pendingSnapshotDelay: PendingSnapshotDelay
) async throws {
    let recordRefreshCompletion: @Sendable () async -> Void = {
        await pendingSnapshotDelay.recordDelayedPendingScopeRefreshCompletion()
    }
    try await PendingScopeRefreshInstrumentation.$onRefreshCompleted.withValue(recordRefreshCompletion) {
        viewModel.computeScopePreview(tracks: tracks)
        try await pendingSnapshotDelay.waitForCapturedFirstSnapshot()
    }
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

func randomAccessMemoriesMusicKitTracks(year: Int? = nil, secondArtist: String = "Julian Casablancas") -> [Track] {
    [
        Track(
            id: "ram-1",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            year: year
        ),
        Track(
            id: "ram-2",
            name: "Instant Crush",
            artist: secondArtist,
            album: "Random Access Memories",
            year: year
        ),
    ]
}

func randomAccessMemoriesTracksWithAlbumArtist(year: Int? = nil) -> [Track] {
    [
        Track(
            id: "ram-1",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            year: year,
            albumArtist: "Daft Punk"
        ),
        Track(
            id: "ram-2",
            name: "Instant Crush",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            year: year,
            albumArtist: "Daft Punk"
        ),
    ]
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GenreUpdaterWorkflowDashboardStateTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

struct DashboardStateAPIService: ExternalAPIService {
    let year: Int?
    let confidence: Int
    let isDefinitive: Bool
    let beforeAlbumYearLookup: (@Sendable () async -> Void)?

    init(
        year: Int? = nil,
        confidence: Int = 0,
        isDefinitive: Bool = true,
        beforeAlbumYearLookup: (@Sendable () async -> Void)? = nil
    ) {
        self.year = year
        self.confidence = confidence
        self.isDefinitive = isDefinitive
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
            isDefinitive: isDefinitive,
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
    private let cancellingTrackIDs: Set<String>
    private let noChangeTrackIDs: Set<String>
    private let writeHold: LiveBatchHold?
    private var writes: [(trackID: String, property: String, value: String)] = []

    init(
        failingTrackIDs: Set<String> = [],
        cancellingTrackIDs: Set<String> = [],
        noChangeTrackIDs: Set<String> = [],
        writeHold: LiveBatchHold? = nil
    ) {
        self.failingTrackIDs = failingTrackIDs
        self.cancellingTrackIDs = cancellingTrackIDs
        self.noChangeTrackIDs = noChangeTrackIDs
        self.writeHold = writeHold
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
        if let writeHold {
            await writeHold.holdOnce()
            try Task.checkCancellation()
        }
        if cancellingTrackIDs.contains(trackID) {
            throw CancellationError()
        }
        if failingTrackIDs.contains(trackID) {
            throw DashboardStateScriptWriteError(trackID: trackID)
        }
        writes.append((trackID: trackID, property: property, value: value))
        if noChangeTrackIDs.contains(trackID) {
            return .noChange
        }
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
    private var entries: [PendingAlbumEntry]
    private let seededDueEntries: [PendingAlbumEntry]?
    private let seededProblematicAlbums: [ProblematicPendingAlbum]
    private let pendingSnapshotDelay: PendingSnapshotDelay?
    private let timestampUpdateFailure: (any Error)?
    private var removals: [(artist: String, album: String)] = []
    private var timestampUpdates = 0

    init(
        entries: [PendingAlbumEntry],
        dueEntries: [PendingAlbumEntry]? = nil,
        problematicAlbums: [ProblematicPendingAlbum] = [],
        pendingSnapshotDelay: PendingSnapshotDelay? = nil,
        timestampUpdateFailure: (any Error)? = nil
    ) {
        self.entries = entries
        self.seededDueEntries = dueEntries
        self.seededProblematicAlbums = problematicAlbums
        self.pendingSnapshotDelay = pendingSnapshotDelay
        self.timestampUpdateFailure = timestampUpdateFailure
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
        let key = AlbumIdentity.key(artist: artist, album: album)
        entries.removeAll { AlbumIdentity.key(artist: $0.artist, album: $0.album) == key }
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
        let snapshot = (entries, currentDueEntries())
        await pendingSnapshotDelay?.waitAfterCapturingFirstSnapshot()
        return snapshot
    }

    func getProblematicPendingAlbums(minAttempts: Int) async -> [ProblematicPendingAlbum] {
        await pendingSnapshotDelay?.recordProblematicCountRequest()
        let currentEntryKeys = currentEntryKeys()
        return seededProblematicAlbums.filter { problematicAlbum in
            problematicAlbum.totalAttempts >= minAttempts
                && currentEntryKeys.contains(Self.key(for: problematicAlbum.entry))
        }
    }

    func shouldAutoVerify() async -> Bool {
        true
    }

    func updateVerificationTimestamp() async throws {
        if let timestampUpdateFailure {
            throw timestampUpdateFailure
        }
        timestampUpdates += 1
    }

    func removedAlbums() -> [(artist: String, album: String)] {
        removals
    }

    func verificationTimestampUpdateCount() -> Int {
        timestampUpdates
    }

    private func currentDueEntries() -> [PendingAlbumEntry] {
        guard let seededDueEntries else { return entries }

        let currentEntryKeys = currentEntryKeys()
        return seededDueEntries.filter { currentEntryKeys.contains(Self.key(for: $0)) }
    }

    private func currentEntryKeys() -> Set<String> {
        Set(entries.map(Self.key(for:)))
    }

    private static func key(for entry: PendingAlbumEntry) -> String {
        AlbumIdentity.key(artist: entry.artist, album: entry.album)
    }
}

actor PendingSnapshotDelay {
    private enum Timeout: Error, CustomStringConvertible {
        case firstSnapshot
        case delayedRefreshCompletion

        var description: String {
            switch self {
            case .firstSnapshot:
                "pending scope refresh did not capture its first snapshot before timeout"
            case .delayedRefreshCompletion:
                "delayed pending scope refresh did not complete before timeout"
            }
        }
    }

    private static let maximumWaitIterations = 200
    private var shouldDelayFirstSnapshot = true
    private var hasCapturedFirstSnapshot = false
    private var isFirstSnapshotReleased = false
    private var hasReturnedDelayedSnapshot = false
    private var hasCompletedDelayedPendingScopeRefresh = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitAfterCapturingFirstSnapshot() async {
        guard shouldDelayFirstSnapshot else { return }

        shouldDelayFirstSnapshot = false
        hasCapturedFirstSnapshot = true

        if !isFirstSnapshotReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        hasReturnedDelayedSnapshot = true
    }

    func waitForCapturedFirstSnapshot() async throws {
        for _ in 0 ..< Self.maximumWaitIterations {
            if hasCapturedFirstSnapshot { return }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw Timeout.firstSnapshot
    }

    func releaseFirstSnapshot() {
        isFirstSnapshotReleased = true
        resumeAll(&releaseContinuations)
    }

    private func resumeAll(_ continuations: inout [CheckedContinuation<Void, Never>]) {
        let continuationsToResume = continuations
        continuations.removeAll()
        for continuation in continuationsToResume {
            continuation.resume()
        }
    }

    func recordProblematicCountRequest() {
        // Hook retained for delayed snapshot tests that need the service call to stay observable.
    }

    func recordDelayedPendingScopeRefreshCompletion() {
        guard hasReturnedDelayedSnapshot else { return }

        hasCompletedDelayedPendingScopeRefresh = true
    }

    func waitForDelayedPendingScopeRefreshCompletion() async throws {
        for _ in 0 ..< Self.maximumWaitIterations {
            if hasCompletedDelayedPendingScopeRefresh { return }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw Timeout.delayedRefreshCompletion
    }
}

actor WorkflowTrackIDMapper: TrackIDMapping {
    private var enrichedTracks: [String: Track]
    private var appleScriptIDsByMusicKitID: [String: String]

    init(
        enrichedTracks: [Track],
        appleScriptIDsByMusicKitID: [String: String]
    ) {
        self.enrichedTracks = Dictionary(uniqueKeysWithValues: enrichedTracks.map { ($0.id, $0) })
        self.appleScriptIDsByMusicKitID = appleScriptIDsByMusicKitID
    }

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        appleScriptIDsByMusicKitID[musicKitID]
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        enrichedTracks[musicKitTrack.id]
    }

    func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
        // These tests seed mappings directly.
    }

    func seed(
        enrichedTracks newEnrichedTracks: [Track],
        appleScriptIDsByMusicKitID newAppleScriptIDs: [String: String]
    ) {
        for track in newEnrichedTracks {
            enrichedTracks[track.id] = track
        }
        appleScriptIDsByMusicKitID.merge(newAppleScriptIDs) { _, newValue in newValue }
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        enrichedTracks[musicKitID] != nil && appleScriptIDsByMusicKitID[musicKitID] != nil
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
