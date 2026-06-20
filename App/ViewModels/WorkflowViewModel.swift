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
    var proposedChanges: [ProposedChange] = []
    var result: BatchUpdateResult?
    var completedEntries: [ChangeLogEntry] = []
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

    private func startDryRun(tracks: [Track]) {
        phase = .scanning
        processedCount = 0
        trackStatuses = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, TrackProcessingStatus.queued) })
        currentTrackID = nil

        processingTask = Task {
            do {
                let options = UpdateOptions(
                    updateGenre: updateGenre,
                    updateYear: updateYear,
                    cleanTrackNames: cleanTrackNames,
                    cleanAlbumNames: cleanAlbumNames,
                    minConfidence: confidencePercentage,
                    autoAccept: false
                )

                var allChanges: [ProposedChange] = []
                let total = tracks.count
                let albumGroups = Self.groupTracksByAlbum(tracks)

                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation()

                    currentTrackID = track.id
                    trackStatuses[track.id] = .analyzing

                    progress = ProgressUpdate(
                        phase: .analyzing,
                        current: index + 1,
                        total: total,
                        message: "Analyzing: \(track.name)"
                    )
                    processedCount = index + 1

                    let changes = try await updateCoordinator.updateTrack(
                        track,
                        albumTracks: albumGroups[Self.albumKey(for: track)] ?? [],
                        options: options,
                        dryRun: true
                    )
                    allChanges.append(contentsOf: changes)

                    trackStatuses[track.id] = .done
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
            let preflightResult = await runMaintenancePreflight?()
            if Task.isCancelled {
                phase = .configure
                progress = nil
                return
            }
            maintenancePreflightResult = preflightResult

            if shouldRunBatchProcessing {
                startBatchProcessing(tracks: tracks)
            } else {
                startDryRun(tracks: tracks)
            }
        }
    }

    var shouldRunBatchProcessing: Bool {
        mode == .fullLibrary && !previewOnly
    }
}
