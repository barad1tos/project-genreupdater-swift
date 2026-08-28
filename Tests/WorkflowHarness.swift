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

func workflowProcessingAdmission(
    trackCount: Int,
    testArtists: [String] = []
) -> ProcessingAdmission {
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: testArtists,
        knownTrackCount: trackCount,
        createdAt: Date(timeIntervalSince1970: 100),
        reason: "workflow-test"
    )
    return workflowProcessingAdmission(scope: scope)
}

func workflowProcessingAdmission(scope: ProcessingScopeSnapshot) -> ProcessingAdmission {
    guard let membership = try? MembershipFingerprint.make(ids: []) else {
        preconditionFailure("Empty membership must have a canonical fingerprint")
    }
    let observedAt = Date(timeIntervalSince1970: 100)
    let fingerprint = membership.fingerprint
    return ProcessingAdmission(
        scopeID: scope.id,
        certificate: ScopeCertificate(
            id: UUID(),
            revision: .initial,
            membership: membership,
            testArtists: scope.normalizedTestArtists,
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: fingerprint,
                observedFingerprint: fingerprint,
                trackCount: scope.knownTrackCount ?? 0
            ),
            observedAt: observedAt
        ),
        maximumMetadataAge: nil
    )
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
    var admissionProbe = WorkflowAdmissionProbe()
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
    let scriptClient = makeScriptClient(input)
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
    let orchestrator = makeFixtureOrchestrator(
        input: input,
        relay: relay,
        runRecords: runRecords,
        observationGate: observationGate
    )
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
        coordinator: coordinator,
        scriptClient: scriptClient,
        batchProcessor: processor,
        runRecords: runRecords,
        observationGate: observationGate,
        orchestrator: orchestrator,
        admissionProbe: input.options.admissionProbe
    )
}

private func makeScriptClient(_ input: WorkflowFixtureInput) -> DashboardStateScriptClient {
    DashboardStateScriptClient(
        failingTrackIDs: input.failingWriteTrackIDs,
        cancellingTrackIDs: input.options.cancellingWriteTrackIDs,
        outcomeTrackIDs: input.options.outcomeTrackIDs,
        noChangeTrackIDs: input.options.noChangeWriteTrackIDs,
        writeHold: input.options.writeHold
    )
}

@MainActor
private func makeFixtureOrchestrator(
    input: WorkflowFixtureInput,
    relay: BatchRunRelay,
    runRecords: FixtureRunRecords,
    observationGate: FixtureSyncGate
) -> RunOrchestrator {
    let failPersistence = input.options.failRunRecordPersistence
    let failTerminalPersistence = input.options.failTerminalRunRecordPersistence
    return RunOrchestrator(dependencies: .init(
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
    let undoCoordinator = UndoCoordinator(musicApp: scriptClient, directory: temporaryDirectory())
    return UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: apiOrchestrator,
            writer: scriptClient,
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
    let admissionProbe = input.options.admissionProbe
    return WorkflowViewModel(
        dependencies: WorkflowViewModel.Dependencies(
            updateCoordinator: coordinator,
            batchProcessor: processor,
            changePreviewPipeline: ChangePreviewPipeline(),
            pendingVerificationService: input.pendingVerificationService,
            featureGate: gate,
            runMaintenancePreflight: input.options.runMaintenancePreflight,
            ensureRecoveryHold: input.options.ensureRecoveryHold,
            clearRecovery: clearRecovery,
            admitProcessing: { tracks, match in
                try await admissionProbe.admit(tracks: tracks, match: match)
            },
            validateProcessing: { admission, tracks, match in
                try await admissionProbe.validate(
                    admission: admission,
                    tracks: tracks,
                    match: match
                )
            },
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
    let coordinator: UpdateCoordinator
    let scriptClient: DashboardStateScriptClient
    let batchProcessor: BatchProcessor
    let runRecords: FixtureRunRecords
    let observationGate: FixtureSyncGate
    let orchestrator: RunOrchestrator
    let admissionProbe: WorkflowAdmissionProbe
}

struct WorkflowAdmissionEvent: Equatable, Sendable {
    let admission: ProcessingAdmission
    let trackIDs: [String]
    let match: AdmissionTrackMatch
}

struct WorkflowAdmissionError: LocalizedError {
    var errorDescription: String? {
        "Fixture processing admission was rejected"
    }
}

actor WorkflowAdmissionProbe {
    private(set) var admitted: [WorkflowAdmissionEvent] = []
    private(set) var validated: [WorkflowAdmissionEvent] = []
    private var admittedTrackIDs: Set<MusicDatabaseTrackID> = []
    private var currentCertificate: ScopeCertificate?
    private var shouldReplaceCertificateAfterAdmission = false

    func replaceCertificateAfterAdmission() {
        shouldReplaceCertificateAfterAdmission = true
    }

    func admit(tracks: [Track], match: AdmissionTrackMatch) throws -> ProcessingAdmission {
        let trackIDs = try databaseIDs(for: tracks)
        let membership = try MembershipFingerprint.make(ids: trackIDs)
        let observedAt = Date(timeIntervalSince1970: 100)
        let fingerprint = membership.fingerprint
        let certificate = ScopeCertificate(
            id: UUID(),
            revision: .initial,
            membership: membership,
            testArtists: [],
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: fingerprint,
                observedFingerprint: fingerprint,
                trackCount: trackIDs.count
            ),
            observedAt: observedAt
        )
        let admission = ProcessingAdmission(
            scopeID: UUID(),
            certificate: certificate,
            maximumMetadataAge: nil
        )
        admittedTrackIDs = Set(trackIDs)
        currentCertificate = certificate
        if shouldReplaceCertificateAfterAdmission {
            currentCertificate = replacing(certificate)
            shouldReplaceCertificateAfterAdmission = false
        }
        admitted.append(WorkflowAdmissionEvent(
            admission: admission,
            trackIDs: tracks.map(\.id),
            match: match
        ))
        return admission
    }

    func validate(
        admission: ProcessingAdmission,
        tracks: [Track],
        match: AdmissionTrackMatch
    ) throws {
        validated.append(WorkflowAdmissionEvent(
            admission: admission,
            trackIDs: tracks.map(\.id),
            match: match
        ))
        let candidateIDs = try Set(databaseIDs(for: tracks))
        guard let currentCertificate,
              admission.certificate.id == currentCertificate.id,
              try hasCurrentEvidence(currentCertificate)
        else {
            throw WorkflowAdmissionError()
        }
        let hasRequiredMatch = switch match {
        case .exactScope:
            candidateIDs == admittedTrackIDs
        case .subset:
            candidateIDs.isSubset(of: admittedTrackIDs)
        }
        guard hasRequiredMatch else { throw WorkflowAdmissionError() }
    }

    private func databaseIDs(for tracks: [Track]) throws -> [MusicDatabaseTrackID] {
        let ids = try tracks.map { track in
            guard let databaseID = MusicDatabaseTrackID(rawValue: track.id) else {
                throw WorkflowAdmissionError()
            }
            return databaseID
        }
        guard Set(ids).count == ids.count else { throw WorkflowAdmissionError() }
        return ids
    }

    private func hasCurrentEvidence(_ certificate: ScopeCertificate) throws -> Bool {
        let fingerprint = try MembershipFingerprint.make(ids: Array(admittedTrackIDs)).fingerprint
        return certificate.membership.fingerprint == fingerprint
            && certificate.requestedFingerprint == fingerprint
            && certificate.observedFingerprint == fingerprint
            && certificate.trackCount == admittedTrackIDs.count
    }

    private func replacing(_ certificate: ScopeCertificate) -> ScopeCertificate {
        ScopeCertificate(
            id: UUID(),
            revision: certificate.revision,
            membership: certificate.membership,
            testArtists: certificate.normalizedTestArtists,
            fieldSet: certificate.fieldSet,
            evidence: certificate.evidence,
            observedAt: certificate.observedAt
        )
    }
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

func makeProposedChange(
    id: String,
    isAccepted: Bool,
    changeType: ChangeType = .genreUpdate
) -> ProposedChange {
    ProposedChange(
        track: Track(
            id: id,
            name: "Track \(id)",
            artist: "Artist",
            album: "Album",
            appleScriptID: id
        ),
        changeType: changeType,
        oldValue: nil,
        newValue: "Rock",
        confidence: 90,
        source: "test",
        isAccepted: isAccepted
    )
}

struct WritableTrackFields {
    var genre: String?
    var year: Int?
    var dateAdded: Date?
    var releaseYear: Int?

    init(
        genre: String? = nil,
        year: Int? = nil,
        dateAdded: Date? = nil,
        releaseYear: Int? = nil
    ) {
        self.genre = genre
        self.year = year
        self.dateAdded = dateAdded
        self.releaseYear = releaseYear
    }
}

func makeWritableTrack(
    _ id: String,
    name: String,
    artist: String,
    album: String,
    fields: WritableTrackFields = .init()
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        genre: fields.genre,
        year: fields.year,
        dateAdded: fields.dateAdded,
        releaseYear: fields.releaseYear,
        appleScriptID: id
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
            trackStatus: TrackKind.subscription.rawValue,
            albumArtist: "Daft Punk"
        ),
        Track(
            id: "ram-2",
            name: "Instant Crush",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            year: year,
            trackStatus: TrackKind.subscription.rawValue,
            albumArtist: "Daft Punk"
        )
    ]
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GenreUpdaterWorkflowDashboardStateTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}
