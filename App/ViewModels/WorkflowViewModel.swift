// WorkflowViewModel.swift — Unified update workflow: dry-run, preview, apply.

import Core
import Foundation
import Observation
import Services

// MARK: - Workflow Mode

/// Determines which tracks the workflow operates on.
enum WorkflowMode: String, CaseIterable, Identifiable {
    case fullLibrary = "Full Library"
    case smartFilter = "Smart Filter"
    case pendingVerification = "Pending"
    case releaseYearRestore = "Restore Years"

    var id: String {
        rawValue
    }

    // swiftformat:disable:next docComments
    // noinspection SpellCheckingInspection
    var icon: String {
        switch self {
        case .fullLibrary: "music.note.list"
        case .smartFilter: "sparkle.magnifyingglass"
        case .pendingVerification: "clock.arrow.circlepath"
        case .releaseYearRestore: "arrow.uturn.backward.circle"
        }
    }
}

// MARK: - Smart Filter Type

/// Preset filters for the Smart Filter mode.
enum SmartFilterType: String, CaseIterable, Identifiable {
    case missingGenres = "Missing Genres"
    case missingYears = "Missing Years"
    case lowConfidence = "Low Confidence"

    var id: String {
        rawValue
    }
}

// MARK: - Workflow Phase

/// Distinct stages of the unified update workflow.
enum WorkflowPhase {
    case configure
    case scanning
    case review
    case applying
    case done
    case paused
    case error(String)
}

// MARK: - Track Processing Status

/// Per-track processing status for streaming progress rows.
enum TrackProcessingStatus: Equatable {
    case queued
    case analyzing
    case writing
    case done
    case failed(String)
    case skipped
}

private struct DryRunInputs {
    let albumTracksByTrackID: [String: [Track]]
    let artistTracksByTrackID: [String: [Track]]
    let options: UpdateOptions
    let yearRunScope: YearRunScope
}

// MARK: - Workflow View Model

/// Unified ViewModel driving genre/year updates for any track selection mode.
///
/// Owns the whole update workflow — dry-run, preview, apply, and the
/// start/pause/resume/cancel progress controls — over the effective
/// processing scope:
/// - **Full Library**: Batch-processes the entire library (feature-gated)
/// - **Smart Filter**: Targets tracks missing genres, years, or with low confidence
@Observable @MainActor
final class WorkflowViewModel {
    // MARK: - Configuration

    var mode: WorkflowMode = .fullLibrary
    var smartFilterType: SmartFilterType = .missingGenres
    var updateGenre: Bool
    var updateYear: Bool
    var forceYearLookup = false
    var cleanTrackNames = false
    var cleanAlbumNames = false
    var previewOnly: Bool
    var minConfidence: Double
    var releaseYearRestoreThreshold: Int

    // MARK: - State

    var phase: WorkflowPhase = .configure
    var progress: ProgressUpdate?
    var processedCount: Int = 0
    var totalCount: Int = 0
    var trackStatuses: [String: TrackProcessingStatus] = [:]
    var currentTrackID: String?
    var scopeTrackCount: Int = 0
    var scopeArtistCount: Int = 0
    var pendingAlbumCount: Int = 0
    var pendingDueAlbumCount: Int = 0
    var pendingSkippedAlbumCount: Int = 0
    var pendingVerificationReportSummary: UpdateRunPendingVerificationSummary?
    var recoveryReportSummary: UpdateRunRecoverySummary?
    var recoveryHoldID: UUID?
    var pendingVerificationRefreshGeneration = 0
    var releaseYearRestoreRunGeneration = 0
    var proposedChanges: [ProposedChange] = []
    var result: BatchUpdateResult?
    var completedEntries: [ChangeLogEntry] = []
    var batchNoOpEntries: [ChangeLogEntry] = []
    var batchFailedTrackIDs: [String] = []
    var batchFailureDescriptions: [String] = []
    var failedCount: Int = 0
    var maintenancePreflightResult: MaintenancePreflightResult?

    // MARK: - Computed Properties

    var confidencePercentage: Int {
        UpdateOptions.clampedConfidencePercent(fromRatio: minConfidence)
    }

    var acceptedCount: Int {
        proposedChanges.filter(\.isAccepted).count
    }

    var isProcessing: Bool {
        switch phase {
        case .scanning, .applying: true
        default: false
        }
    }

    var canStart: Bool {
        guard recoveryHoldID == nil else { return false }
        if case .configure = phase {
            return true
        }
        if case .done = phase {
            return true
        }
        if case .error = phase {
            return true
        }
        return false
    }

    var hasRunnableScope: Bool {
        switch mode {
        case .pendingVerification:
            true
        case .fullLibrary, .smartFilter, .releaseYearRestore:
            scopeTrackCount > 0
        }
    }

    /// Track IDs with their error messages from the most recent run.
    var failedTracks: [(id: String, error: String)] {
        trackStatuses.compactMap { trackID, status in
            if case let .failed(message) = status {
                return (id: trackID, error: message)
            }
            return nil
        }
    }

    // MARK: - Dependencies

    let updateCoordinator: UpdateCoordinator
    let batchProcessor: BatchProcessor
    let changePreviewPipeline: ChangePreviewPipeline
    let pendingVerificationService: (any PendingVerificationService)?
    let featureGate: FeatureGate?
    let runMaintenancePreflight: (() async -> MaintenancePreflightResult?)?
    let ensureRecoveryHold: () async -> Bool
    let clearRecovery: (UUID) async throws -> Void
    let prepareMutationMetadata: (([Track]) async throws -> Void)?
    let resolveIncrementalTracks: ([Track], IncrementalTrackScopeOptions) async -> [Track]
    let invalidateAlbumYearCache: (() async -> Void)?
    let updateIncrementalRunTimestamp: (() async -> Void)?
    let submitBatchRun: ((BatchRunInput) async throws -> RunSubmissionResult)?
    let discardQueuedBatchRuns: (() async -> Void)?
    let problematicAlbumReportMinAttempts: () -> Int
    var defaultUpdateGenre: Bool
    var defaultUpdateYear: Bool
    var defaultPreviewOnly: Bool
    var defaultMinConfidence: Double
    var defaultReleaseYearRestoreThreshold: Int
    var processingTask: Task<Void, Never>?
    /// The stashed work the orchestrator's runner consumes (D3): tracks
    /// and context stay screen-side; only options and count travel in
    /// the run request.
    var pendingBatchExecution: PendingBatchExecution?

    init(
        dependencies: Dependencies,
        defaults: Defaults = Defaults()
    ) {
        updateCoordinator = dependencies.updateCoordinator
        batchProcessor = dependencies.batchProcessor
        changePreviewPipeline = dependencies.changePreviewPipeline
        pendingVerificationService = dependencies.pendingVerificationService
        featureGate = dependencies.featureGate
        runMaintenancePreflight = dependencies.runMaintenancePreflight
        ensureRecoveryHold = dependencies.ensureRecoveryHold
        clearRecovery = dependencies.clearRecovery
        prepareMutationMetadata = dependencies.prepareMutationMetadata
        resolveIncrementalTracks = dependencies.resolveIncrementalTracks
        invalidateAlbumYearCache = dependencies.invalidateAlbumYearCache
        updateIncrementalRunTimestamp = dependencies.updateIncrementalRunTimestamp
        submitBatchRun = dependencies.submitBatchRun
        discardQueuedBatchRuns = dependencies.discardQueuedBatchRuns
        problematicAlbumReportMinAttempts = dependencies.problematicAlbumReportMinAttempts
        defaultUpdateGenre = defaults.updateGenre
        defaultUpdateYear = defaults.updateYear
        defaultPreviewOnly = defaults.previewOnly
        defaultMinConfidence = defaults.minConfidence
        defaultReleaseYearRestoreThreshold = defaults.releaseYearRestoreThreshold
        updateGenre = defaults.updateGenre
        updateYear = defaults.updateYear
        previewOnly = defaults.previewOnly
        minConfidence = defaults.minConfidence
        releaseYearRestoreThreshold = defaults.releaseYearRestoreThreshold
    }

    // MARK: - Start Workflow

    /// Begin the update workflow for the given tracks.
    ///
    /// In **Smart Filter** mode, runs a dry-run first to produce proposed
    /// changes for review. In **Full Library** mode, processes all tracks
    /// through `BatchProcessor` with real-time progress.
    func start(tracks: [Track]) {
        guard canStart else { return }

        maintenancePreflightResult = nil

        if mode == .pendingVerification {
            startPendingVerification(tracks: tracks)
            return
        }

        invalidatePendingVerificationRefreshes()
        pendingVerificationReportSummary = nil

        if mode == .releaseYearRestore {
            startReleaseYearRestore(tracks: tracks)
            return
        }

        let workingTracks = tracksForCurrentMode(tracks)
        totalCount = workingTracks.count
        computeScopePreview(tracks: workingTracks)

        guard requireTrackCapacityForCurrentMode(tracks: workingTracks) else { return }

        startUpdateAfterMaintenancePreflight(tracks: workingTracks)
    }

    // MARK: - Scope Preview

    /// Compute track and artist counts for the current mode/filter selection.
    func computeScopePreview(tracks: [Track]) {
        let filtered = tracksForCurrentMode(tracks)
        scopeTrackCount = filtered.count
        let uniqueArtists = Set(filtered.map(\.artist))
        scopeArtistCount = uniqueArtists.count

        if mode == .pendingVerification {
            refreshPendingScope(tracks: tracks)
        }
    }

    // MARK: - Dry Run (Smart Filter mode)

    private func startDryRun(scope: UpdateTrackScope, contextTracks: [Track]? = nil) {
        let tracks = scope.tracks
        phase = .scanning
        processedCount = 0
        trackStatuses = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, TrackProcessingStatus.queued) })
        currentTrackID = nil

        processingTask = Task {
            do {
                let options = UpdateOptions(
                    updateGenre: updateGenre,
                    updateYear: updateYear,
                    repairExistingGenreMismatches: mode == .fullLibrary,
                    forceYearLookup: forceYearLookup,
                    cleanTrackNames: cleanTrackNames,
                    cleanAlbumNames: cleanAlbumNames,
                    minConfidence: confidencePercentage,
                    autoAccept: false
                )

                var allChanges: [ProposedChange] = []
                let total = tracks.count
                let dryRunInputs = await makeDryRunInputs(
                    for: contextTracks ?? tracks,
                    options: options
                )

                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation()

                    updateDryRunProgress(for: track, index: index, total: total)

                    do {
                        let changes = try await previewChanges(
                            for: track,
                            pass: scope.pass(for: track),
                            inputs: dryRunInputs
                        )
                        allChanges.append(contentsOf: changes)
                        trackStatuses[track.id] = .done
                    } catch let error where Self.isWriteEligibilityError(error) {
                        trackStatuses[track.id] = .skipped
                    }
                }

                let filtered = changePreviewPipeline.filter(
                    changes: allChanges,
                    minConfidence: confidencePercentage
                )
                proposedChanges = filtered

                currentTrackID = nil
                phase = .review
                progress = nil
            } catch is CancellationError {
                currentTrackID = nil
                phase = .configure
                progress = nil
            } catch {
                currentTrackID = nil
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    private func updateDryRunProgress(for track: Track, index: Int, total: Int) {
        currentTrackID = track.id
        trackStatuses[track.id] = .analyzing
        progress = ProgressUpdate(
            phase: .analyzing,
            current: index + 1,
            total: total,
            message: "Analyzing: \(track.name)"
        )
        processedCount = index + 1
    }

    private func previewChanges(
        for track: Track,
        pass: UpdatePass,
        inputs: DryRunInputs
    ) async throws -> [ProposedChange] {
        try await updateCoordinator.updateTrack(
            track,
            albumTracks: inputs.albumTracksByTrackID[track.id] ?? [],
            artistTracks: inputs.artistTracksByTrackID[track.id] ?? [],
            options: inputs.options,
            pass: pass,
            dryRun: true,
            yearRunScope: inputs.yearRunScope
        )
    }

    private func makeDryRunInputs(for tracks: [Track], options: UpdateOptions) async -> DryRunInputs {
        await DryRunInputs(
            albumTracksByTrackID: dryRunAlbumTracksByTrackID(for: tracks),
            artistTracksByTrackID: updateCoordinator.artistContextTracksByTrackID(for: tracks),
            options: options,
            yearRunScope: YearRunScope()
        )
    }

    private func dryRunAlbumTracksByTrackID(for tracks: [Track]) async -> [String: [Track]] {
        await updateCoordinator.albumContextTracksByTrackID(
            for: tracks,
            requiresMutationMetadata: false
        )
    }

    // MARK: - Apply Accepted Changes

    /// Apply only the accepted proposed changes from the review phase —
    /// as an orchestrator run (slice-12 PR C): the record and recovery
    /// belong to the run; this screen keeps only progress and phases.
    func applyAccepted() {
        guard !previewOnly else { return }
        guard !isProcessing else { return }

        let accepted = proposedChanges.filter(\.isAccepted)
        guard !accepted.isEmpty else { return }
        guard let submitBatchRun else {
            phase = .error("Run service is unavailable")
            progress = nil
            return
        }

        phase = .applying

        processingTask = Task {
            guard await !stopForRecoveryHold() else { return }
            let acceptedTracks = Self.uniqueTracks(accepted.map(\.track))
            guard await prepareMutationMetadataIfNeeded(tracks: acceptedTracks) else { return }

            let options = UpdateOptions(
                updateGenre: updateGenre,
                updateYear: updateYear,
                repairExistingGenreMismatches: mode == .fullLibrary,
                forceYearLookup: forceYearLookup,
                cleanTrackNames: cleanTrackNames,
                cleanAlbumNames: cleanAlbumNames,
                minConfidence: confidencePercentage,
                autoAccept: false
            )
            totalCount = max(totalCount, acceptedTracks.count)
            pendingBatchExecution = .applyAccepted(AcceptedChangesBatch(
                accepted: accepted,
                trackCount: acceptedTracks.count,
                options: options
            ))
            do {
                let submission = try await submitBatchRun(
                    BatchRunInput(options: options, trackCount: acceptedTracks.count)
                )
                applyBatchSubmissionResult(submission)
            } catch is CancellationError {
                pendingBatchExecution = nil
                phase = .configure
                progress = nil
            } catch {
                pendingBatchExecution = nil
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    func makeApplyProgressHandler() -> @Sendable (ProgressUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor in
                self?.progress = update
            }
        }
    }

    private static func isWriteEligibilityError(_ error: any Error) -> Bool {
        switch error {
        case UpdateCoordinatorError.trackNotEditable, UpdateCoordinatorError.missingAppleScriptID:
            true
        default:
            false
        }
    }

    // MARK: - Batch Controls

    /// Pause the batch processor (Full Library mode only).
    func pause() async {
        guard mode == .fullLibrary, case .scanning = phase else { return }
        await batchProcessor.pause()
        phase = .paused
    }

    /// Resume the batch processor from paused state.
    func resume() async {
        guard mode == .fullLibrary, case .paused = phase else { return }
        await batchProcessor.resume()
        phase = .scanning
    }

    private func startUpdateAfterMaintenancePreflight(tracks: [Track]) {
        phase = .scanning
        processedCount = 0
        progress = ProgressUpdate(
            phase: .fetching,
            current: 0,
            total: tracks.count,
            message: "Checking library state"
        )

        processingTask = Task { [runMaintenancePreflight] in
            let processingScope = await scopeForProcessing(tracks)
            let processingTracks = processingScope.tracks
            guard !stopProcessingIfCancelled() else { return }

            totalCount = processingTracks.count
            computeScopePreview(tracks: processingTracks)
            let shouldRunBatch = shouldRunBatchProcessing
            guard shouldRunBatch || !processingTracks.isEmpty else {
                finishEmptyProcessingRun()
                return
            }

            if shouldRunBatch {
                guard await prepareWriteMetadata(for: processingTracks) else { return }
            }

            let preflightResult = await runMaintenancePreflight?()
            guard !stopProcessingIfCancelled() else { return }
            maintenancePreflightResult = preflightResult

            let pendingVerificationOutcome: PendingEntryOutcome
            if shouldRunBatch {
                pendingVerificationOutcome = await runPendingVerificationBeforeBatchIfDue(
                    preflightResult: preflightResult,
                    tracks: tracks
                )
                guard !stopProcessingIfCancelled() else { return }
                guard isProcessing else { return }
            } else {
                pendingVerificationOutcome = PendingEntryOutcome()
            }

            let remainingScope = processingScope.afterYearWrites(
                trackIDs: Set(pendingVerificationOutcome.successfulTrackIDs),
                preserveYearPass: forceYearLookup
            )
            guard !shouldStopAfterPendingPreflight(
                pendingVerificationOutcome,
                processingTracks: remainingScope.tracks
            ) else {
                return
            }

            if shouldRunBatch {
                startBatchProcessing(
                    tracks: remainingScope.tracks,
                    contextTracks: tracks,
                    preflightOutcome: pendingVerificationOutcome,
                    trackPasses: remainingScope.trackPasses
                )
            } else {
                startDryRun(scope: processingScope, contextTracks: tracks)
            }
        }
    }

    func prepareMutationMetadataIfNeeded(tracks: [Track]) async -> Bool {
        guard !tracks.isEmpty else { return true }
        guard let prepareMutationMetadata else {
            phase = .error("Music write metadata service is unavailable")
            progress = nil
            return false
        }

        progress = ProgressUpdate(
            phase: .fetching,
            current: 0,
            total: tracks.count,
            message: "Preparing Music write metadata"
        )
        do {
            try await prepareMutationMetadata(tracks)
        } catch is CancellationError {
            finishCancelledProcessing()
            return false
        } catch {
            phase = .error(error.localizedDescription)
            progress = nil
            return false
        }
        if Task.isCancelled {
            finishCancelledProcessing()
            return false
        }
        return true
    }

    func prepareWriteMetadata(for tracks: [Track]) async -> Bool {
        guard await !stopForRecoveryHold() else { return false }
        return await prepareMutationMetadataIfNeeded(tracks: tracks)
    }

    func stopForRecoveryHold() async -> Bool {
        if recoveryHoldID == nil {
            recoveryHoldID = await batchProcessor.recoveryHoldID()
        }
        if recoveryHoldID == nil {
            guard await ensureRecoveryHold() else { return false }
            recoveryHoldID = await batchProcessor.recoveryHoldID()
        }

        phase = .error("Previous run needs recovery before writes continue.")
        progress = nil
        return true
    }

    func handleUnknownOutcome(_ outcome: AppleScriptOutcomeError) async {
        recoveryHoldID = await batchProcessor.beginRecoveryHold()
        phase = .error(outcome.localizedDescription)
        progress = nil
    }

    private func stopProcessingIfCancelled() -> Bool {
        guard Task.isCancelled else { return false }
        finishCancelledProcessing()
        return true
    }

    func finishCancelledProcessing() {
        phase = .configure
        progress = nil
    }

    private func shouldStopAfterPendingPreflight(
        _ outcome: PendingEntryOutcome,
        processingTracks: [Track]
    ) -> Bool {
        if !outcome.failedTrackIDs.isEmpty {
            finishEmptyProcessingRun(preflightOutcome: outcome)
            return true
        }
        if processingTracks.isEmpty {
            finishEmptyProcessingRun(preflightOutcome: outcome)
            return true
        }
        return false
    }

    private func scopeForProcessing(_ tracks: [Track]) async -> UpdateTrackScope {
        guard mode == .fullLibrary else {
            return UpdateTrackScope(tracks: tracks, trackPasses: [:])
        }
        if updateYear, forceYearLookup {
            return UpdateTrackScope(tracks: tracks, trackPasses: [:])
        }
        let primaryTracks = await resolveIncrementalTracks(
            tracks,
            IncrementalTrackScopeOptions(updateGenre: updateGenre)
        )
        return UpdateTrackScopeResolver.stageScope(
            libraryTracks: tracks,
            primaryTracks: primaryTracks,
            includesYearSweep: updateYear
        )
    }

    private func finishEmptyProcessingRun(preflightOutcome: PendingEntryOutcome = PendingEntryOutcome()) {
        result = BatchUpdateResult(
            entries: preflightOutcome.completed,
            failedTrackIDs: preflightOutcome.failedTrackIDs,
            errorDescriptions: preflightOutcome.errorDescriptions
        )
        completedEntries = preflightOutcome.completed
        proposedChanges = []
        processedCount = preflightOutcome.processedCount
        failedCount = preflightOutcome.failedTrackIDs.count
        if preflightOutcome.isEmpty {
            trackStatuses = [:]
        }
        currentTrackID = nil
        phase = .done
        progress = nil
    }

    var shouldRunBatchProcessing: Bool {
        mode == .fullLibrary && !previewOnly
    }
}
