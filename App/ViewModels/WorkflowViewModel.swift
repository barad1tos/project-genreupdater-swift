// WorkflowViewModel.swift — Unified update workflow (replaces UpdateViewModel + BatchViewModel).

import Core
import Foundation
import Observation
import Services

// MARK: - Workflow Mode

/// Determines which tracks the workflow operates on.
enum WorkflowMode: String, CaseIterable, Identifiable {
    case selectedTracks = "Selected Tracks"
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
        case .selectedTracks: "hand.tap"
        case .fullLibrary: "music.note.list"
        case .smartFilter: "sparkle.magnifyingglass"
        case .pendingVerification: "clock.arrow.circlepath"
        case .releaseYearRestore: "arrow.uturn.backward.circle"
        }
    }

    var requiresFeatureGate: Bool {
        self == .fullLibrary
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

// MARK: - Workflow View Model

/// Unified ViewModel driving genre/year updates for any track selection mode.
///
/// Merges the responsibilities of `UpdateViewModel` (dry-run → preview → apply)
/// and `BatchViewModel` (start/pause/resume/cancel with progress) into a single
/// workflow with three operating modes:
/// - **Selected Tracks**: Analyzes and applies changes to a specific set of tracks
/// - **Full Library**: Batch-processes the entire library (feature-gated)
/// - **Smart Filter**: Targets tracks missing genres, years, or with low confidence
@Observable @MainActor
final class WorkflowViewModel {
    // MARK: - Configuration

    var mode: WorkflowMode = .selectedTracks
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
    var pendingVerificationRefreshGeneration = 0
    var proposedChanges: [ProposedChange] = []
    var result: BatchUpdateResult?
    var completedEntries: [ChangeLogEntry] = []
    var batchNoOpEntries: [ChangeLogEntry] = []
    var dryRunReport: DryRunReport?
    var failedCount: Int = 0
    var maintenancePreflightResult: MaintenancePreflightResult?

    // MARK: - Computed Properties

    var confidencePercentage: Int {
        Int(minConfidence * 100)
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
        if case .configure = phase { return true }
        if case .done = phase { return true }
        if case .error = phase { return true }
        return false
    }

    var hasRunnableScope: Bool {
        switch mode {
        case .pendingVerification:
            true
        case .selectedTracks, .fullLibrary, .smartFilter, .releaseYearRestore:
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
    let recordProcessedTracks: (Int) -> Void
    let runMaintenancePreflight: (() async -> MaintenancePreflightResult?)?
    let resolveIncrementalTracks: ([Track], IncrementalTrackScopeOptions) async -> [Track]
    let invalidateAlbumYearCache: (() async -> Void)?
    let updateIncrementalRunTimestamp: (() async -> Void)?
    let problematicAlbumReportMinAttempts: () -> Int
    var defaultUpdateGenre: Bool
    var defaultUpdateYear: Bool
    var defaultPreviewOnly: Bool
    var defaultMinConfidence: Double
    var defaultReleaseYearRestoreThreshold: Int
    var processingTask: Task<Void, Never>?

    init(
        dependencies: Dependencies,
        defaults: Defaults = Defaults()
    ) {
        updateCoordinator = dependencies.updateCoordinator
        batchProcessor = dependencies.batchProcessor
        changePreviewPipeline = dependencies.changePreviewPipeline
        pendingVerificationService = dependencies.pendingVerificationService
        featureGate = dependencies.featureGate
        recordProcessedTracks = dependencies.recordProcessedTracks
        runMaintenancePreflight = dependencies.runMaintenancePreflight
        resolveIncrementalTracks = dependencies.resolveIncrementalTracks
        invalidateAlbumYearCache = dependencies.invalidateAlbumYearCache
        updateIncrementalRunTimestamp = dependencies.updateIncrementalRunTimestamp
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
    /// In **Selected Tracks** and **Smart Filter** modes, runs a dry-run first
    /// to produce proposed changes for review. In **Full Library** mode, processes
    /// all tracks through `BatchProcessor` with real-time progress.
    func start(tracks: [Track]) {
        guard canStart else { return }

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

    // MARK: - Dry Run (Selected + Smart Filter modes)

    private func startDryRun(tracks: [Track], contextTracks: [Track]? = nil) {
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
                let contextTracks = contextTracks ?? tracks
                let albumTracksByTrackID = await updateCoordinator.albumContextTracksByTrackID(for: contextTracks)
                let artistGroups = Self.groupTracksByArtist(contextTracks)

                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation()

                    updateDryRunProgress(for: track, index: index, total: total)

                    do {
                        let changes = try await previewChanges(
                            for: track,
                            albumTracksByTrackID: albumTracksByTrackID,
                            artistGroups: artistGroups,
                            options: options
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

                if previewOnly {
                    dryRunReport = DryRunReport(proposedChanges: filtered)
                }

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
        albumTracksByTrackID: [String: [Track]],
        artistGroups: [String: [Track]],
        options: UpdateOptions
    ) async throws -> [ProposedChange] {
        try await updateCoordinator.updateTrack(
            track,
            albumTracks: albumTracksByTrackID[track.id] ?? [],
            artistTracks: artistGroups[Self.artistKey(for: track)] ?? [],
            options: options,
            dryRun: true
        )
    }

    // MARK: - Apply Accepted Changes

    /// Apply only the accepted proposed changes from the review phase.
    func applyAccepted() {
        guard !previewOnly else { return }

        let accepted = proposedChanges.filter(\.isAccepted)
        guard !accepted.isEmpty else { return }

        phase = .applying

        processingTask = Task {
            do {
                let batchResult = try await updateCoordinator.applyAcceptedChanges(
                    accepted,
                    progressHandler: makeApplyProgressHandler()
                )

                result = batchResult
                recordAppliedTrackUsage(from: batchResult)
                phase = .done
                progress = nil
            } catch is CancellationError {
                phase = .configure
                progress = nil
            } catch {
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    private func makeApplyProgressHandler() -> @Sendable (ProgressUpdate) -> Void {
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
            let processingTracks = await tracksForProcessing(tracks)
            if Task.isCancelled {
                phase = .configure
                progress = nil
                return
            }

            totalCount = processingTracks.count
            computeScopePreview(tracks: processingTracks)
            let shouldRunBatch = shouldRunBatchProcessing
            guard shouldRunBatch || !processingTracks.isEmpty else {
                finishEmptyProcessingRun()
                return
            }

            let preflightResult = await runMaintenancePreflight?()
            if Task.isCancelled {
                phase = .configure
                progress = nil
                return
            }
            maintenancePreflightResult = preflightResult

            let pendingVerificationOutcome: PendingEntryOutcome
            if shouldRunBatch {
                pendingVerificationOutcome = await runPendingVerificationBeforeBatchIfDue(
                    preflightResult: preflightResult,
                    tracks: tracks
                )
                if Task.isCancelled {
                    phase = .configure
                    progress = nil
                    return
                }
                guard isProcessing else { return }
            } else {
                pendingVerificationOutcome = PendingEntryOutcome()
            }

            guard !shouldStopAfterPendingPreflight(
                pendingVerificationOutcome,
                processingTracks: processingTracks
            ) else {
                return
            }

            if shouldRunBatch {
                startBatchProcessing(
                    tracks: processingTracks,
                    contextTracks: tracks,
                    preflightOutcome: pendingVerificationOutcome
                )
            } else {
                startDryRun(tracks: processingTracks, contextTracks: tracks)
            }
        }
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

    private func tracksForProcessing(_ tracks: [Track]) async -> [Track] {
        guard mode == .fullLibrary else { return tracks }
        if updateYear, forceYearLookup {
            return tracks
        }
        return await resolveIncrementalTracks(
            tracks,
            IncrementalTrackScopeOptions(updateGenre: updateGenre)
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
        dryRunReport = previewOnly ? DryRunReport(proposedChanges: []) : nil
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
