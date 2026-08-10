import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@MainActor
func makeWorkflowViewModel() -> WorkflowViewModel {
    makeWorkflowFixture().viewModel
}

func noOpPrepareMutationMetadata(_: [Track]) async throws {
    // Default test hook intentionally skips mutation metadata preparation.
}

struct WorkflowFixtureOptions {
    var apiServices: APIOrchestratorServices?
    var tier: Tier = .pro
    var cancellingWriteTrackIDs: Set<String> = []
    var outcomeTrackIDs: Set<String> = []
    var noChangeWriteTrackIDs: Set<String> = []
    var writeHold: LiveBatchHold?
    var checkpointDirectory: URL = temporaryDirectory()
    var recoverySuiteName: String?
    var problematicAlbumReportMinAttempts: () -> Int = { 3 }
    var runMaintenancePreflight: (() async -> MaintenancePreflightResult?)?
    var ensureRecoveryHold: () async -> Bool = { false }
    var clearRecovery: ((UUID) async throws -> Void)?
    var invalidateAlbumYearCache: (() async -> Void)?
    var updateIncrementalRunTimestamp: (() async -> Void)?
    var failRunRecordPersistence = false
    var failTerminalRunRecordPersistence = false
    var recordTrackUsage: (Int) -> Void = { _ in
        // Most workflow fixtures do not observe subscription persistence.
    }
    var featureGate: FeatureGate?
}

private struct WorkflowFixtureInput {
    let apiService: DashboardStateAPIService
    let failingWriteTrackIDs: Set<String>
    let resolveIncrementalTracks: ([Track], IncrementalTrackScopeOptions) async -> [Track]
    let pendingVerificationService: (any PendingVerificationService)?
    let idMapper: (any TrackIDMapping)?
    let prepareMutationMetadata: (([Track]) async throws -> Void)?
    let options: WorkflowFixtureOptions
}

@MainActor
func makeWorkflowFixture(
    apiService: DashboardStateAPIService = DashboardStateAPIService(),
    failingWriteTrackIDs: Set<String> = [],
    resolveIncrementalTracks: @escaping (
        [Track],
        IncrementalTrackScopeOptions
    ) async -> [Track] = { tracks, _ in tracks },
    pendingVerificationService: (any PendingVerificationService)? = nil,
    idMapper: (any TrackIDMapping)? = nil,
    prepareMutationMetadata: (([Track]) async throws -> Void)? = noOpPrepareMutationMetadata,
    configure: (inout WorkflowFixtureOptions) -> Void = { _ in
        // Default fixtures keep workflow options unchanged.
    }
) -> WorkflowFixture {
    var options = WorkflowFixtureOptions()
    configure(&options)
    return assembleWorkflowFixture(WorkflowFixtureInput(
        apiService: apiService,
        failingWriteTrackIDs: failingWriteTrackIDs,
        resolveIncrementalTracks: resolveIncrementalTracks,
        pendingVerificationService: pendingVerificationService,
        idMapper: idMapper,
        prepareMutationMetadata: prepareMutationMetadata,
        options: options
    ))
}

@MainActor
private func assembleWorkflowFixture(_ input: WorkflowFixtureInput) -> WorkflowFixture {
    let scriptClient = DashboardStateScriptClient(
        failingTrackIDs: input.failingWriteTrackIDs,
        cancellingTrackIDs: input.options.cancellingWriteTrackIDs,
        outcomeTrackIDs: input.options.outcomeTrackIDs,
        noChangeTrackIDs: input.options.noChangeWriteTrackIDs,
        writeHold: input.options.writeHold
    )
    let cache = DashboardStateCacheService()
    let coordinator = makeWorkflowCoordinator(
        input: input,
        scriptClient: scriptClient,
        cache: cache
    )
    let gate = input.options.featureGate ?? FeatureGate(
        fixedTier: input.options.tier,
        usageRecorder: input.options.recordTrackUsage
    )
    let processor = BatchProcessor(
        checkpointManager: CheckpointManager(
            directory: input.options.checkpointDirectory,
            recoverySuiteName: input.options.recoverySuiteName
        ),
        featureGate: gate
    )
    let clearRecovery = input.options.clearRecovery ?? { id in
        try await processor.clearRecovery(batchID: id)
    }
    let relay = BatchRunRelay()
    let runRecords = FixtureRunRecords()
    let observationGate = FixtureSyncGate()
    let failPersistence = input.options.failRunRecordPersistence
    let failTerminalPersistence = input.options.failTerminalRunRecordPersistence
    let orchestrator = RunOrchestrator(dependencies: .init(
        synchronizeLibrary: { await observationGate.sync() },
        persistRunRecord: { record in
            if failPersistence || (failTerminalPersistence && record.finishedAt != nil) {
                throw FixtureRecordWriteError()
            }
            await runRecords.append(record)
        },
        runBatchUpdate: { batchInput, runID in
            try await relay.perform(batchInput, runID)
        }
    ))
    let viewModel = makeFixtureViewModel(
        input: input,
        coordinator: coordinator,
        processor: processor,
        gate: gate,
        clearRecovery: clearRecovery,
        submitBatchRun: { batchInput in
            await orchestrator.submit(.manualBatchUpdate(
                input: batchInput,
                requestedTestArtists: [],
                knownTrackCount: batchInput.trackCount
            ))
        },
        discardQueuedBatchRuns: {
            await orchestrator.discardPendingBatchRuns()
        }
    )
    relay.viewModel = viewModel
    return WorkflowFixture(
        viewModel: viewModel,
        scriptClient: scriptClient,
        batchProcessor: processor,
        runRecords: runRecords,
        observationGate: observationGate,
        orchestrator: orchestrator
    )
}

struct FixtureRecordWriteError: Error {}

/// A production-shaped bridge for fixtures: the orchestrator's Sendable
/// runner slot reaches the fixture's view-model exactly like the app's
/// batchRunProvider does.
@MainActor
private final class BatchRunRelay {
    weak var viewModel: WorkflowViewModel?

    nonisolated init() {}

    func perform(_ input: BatchRunInput, _ runID: RunID) async throws -> BatchUpdateResult {
        guard let viewModel else {
            throw AppDependencyServiceError.batchRunnerUnavailable
        }
        return try await viewModel.performBatchRunWork(input: input, runID: runID)
    }
}

@MainActor
private func makeWorkflowCoordinator(
    input: WorkflowFixtureInput,
    scriptClient: DashboardStateScriptClient,
    cache: DashboardStateCacheService
) -> UpdateCoordinator {
    let apiOrchestrator = makeWorkflowAPI(
        service: input.apiService,
        services: input.options.apiServices,
        cache: cache
    )
    let undoCoordinator = UndoCoordinator(scriptBridge: scriptClient, directory: temporaryDirectory())
    return UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: apiOrchestrator,
            scriptBridge: scriptClient,
            trackStore: DashboardStateTrackStore(),
            cache: cache,
            undoCoordinator: undoCoordinator,
            idMapper: input.idMapper,
            pendingVerificationService: input.pendingVerificationService
        ),
        genreDeterminator: GenreDeterminator()
    )
}

@MainActor
private func makeFixtureViewModel(
    input: WorkflowFixtureInput,
    coordinator: UpdateCoordinator,
    processor: BatchProcessor,
    gate: FeatureGate,
    clearRecovery: @escaping (UUID) async throws -> Void,
    submitBatchRun: ((BatchRunInput) async throws -> RunSubmissionResult)? = nil,
    discardQueuedBatchRuns: (() async -> Void)? = nil
) -> WorkflowViewModel {
    WorkflowViewModel(
        dependencies: WorkflowViewModel.Dependencies(
            updateCoordinator: coordinator,
            batchProcessor: processor,
            changePreviewPipeline: ChangePreviewPipeline(),
            pendingVerificationService: input.pendingVerificationService,
            featureGate: gate,
            runMaintenancePreflight: input.options.runMaintenancePreflight,
            ensureRecoveryHold: input.options.ensureRecoveryHold,
            clearRecovery: clearRecovery,
            prepareMutationMetadata: input.prepareMutationMetadata,
            resolveIncrementalTracks: input.resolveIncrementalTracks,
            invalidateAlbumYearCache: input.options.invalidateAlbumYearCache,
            updateIncrementalRunTimestamp: input.options.updateIncrementalRunTimestamp,
            submitBatchRun: submitBatchRun,
            discardQueuedBatchRuns: discardQueuedBatchRuns,
            problematicAlbumReportMinAttempts: input.options.problematicAlbumReportMinAttempts
        )
    )
}

private func makeWorkflowAPI(
    service: DashboardStateAPIService,
    services: APIOrchestratorServices?,
    cache: DashboardStateCacheService
) -> APIOrchestrator {
    var configuration = APIOrchestratorConfiguration()
    configuration.cache = cache
    return APIOrchestrator(
        services: services ?? APIOrchestratorServices(
            musicBrainz: service,
            discogs: service,
            appleMusic: service
        ),
        configuration: configuration
    )
}

struct WorkflowFixture {
    let viewModel: WorkflowViewModel
    let scriptClient: DashboardStateScriptClient
    let batchProcessor: BatchProcessor
    let runRecords: FixtureRunRecords
    let observationGate: FixtureSyncGate
    let orchestrator: RunOrchestrator
}

actor FixtureRunRecords {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

/// Arms an orchestrator observation that blocks until released, so app
/// pins can observe the queued-batch path deterministically.
actor FixtureSyncGate {
    private var isArmed = false
    private var isReleased = false
    private var isEntered = false
    private var enterContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
    }

    func sync() async -> SyncResult {
        guard isArmed, !isReleased else { return SyncResult() }
        isEntered = true
        for continuation in enterContinuations {
            continuation.resume()
        }
        enterContinuations = []
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        return SyncResult()
    }

    func waitUntilEntered() async {
        if isEntered {
            return
        }
        await withCheckedContinuation { continuation in
            enterContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }
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
        )
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
        )
    ]
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GenreUpdaterWorkflowDashboardStateTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}
