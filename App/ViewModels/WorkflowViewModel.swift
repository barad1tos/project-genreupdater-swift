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

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .selectedTracks: "hand.tap"
        case .fullLibrary: "music.note.list"
        case .smartFilter: "sparkle.magnifyingglass"
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
enum TrackProcessingStatus {
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
    var previewOnly: Bool
    var minConfidence: Double

    // MARK: - State

    var phase: WorkflowPhase = .configure
    var progress: ProgressUpdate?
    var processedCount: Int = 0
    var totalCount: Int = 0
    var trackStatuses: [String: TrackProcessingStatus] = [:]
    var currentTrackID: String?
    var scopeTrackCount: Int = 0
    var scopeArtistCount: Int = 0
    var proposedChanges: [ProposedChange] = []
    var result: BatchUpdateResult?
    var completedEntries: [ChangeLogEntry] = []
    var dryRunReport: DryRunReport?
    var failedCount: Int = 0

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

    private let updateCoordinator: UpdateCoordinator
    private let batchProcessor: BatchProcessor
    private let changePreviewPipeline: ChangePreviewPipeline
    private var defaultUpdateGenre: Bool
    private var defaultUpdateYear: Bool
    private var defaultPreviewOnly: Bool
    private var defaultMinConfidence: Double
    private var processingTask: Task<Void, Never>?

    init(
        updateCoordinator: UpdateCoordinator,
        batchProcessor: BatchProcessor,
        changePreviewPipeline: ChangePreviewPipeline,
        defaultUpdateGenre: Bool = true,
        defaultUpdateYear: Bool = true,
        defaultPreviewOnly: Bool = true,
        defaultMinConfidence: Double = 0.6
    ) {
        self.updateCoordinator = updateCoordinator
        self.batchProcessor = batchProcessor
        self.changePreviewPipeline = changePreviewPipeline
        self.defaultUpdateGenre = defaultUpdateGenre
        self.defaultUpdateYear = defaultUpdateYear
        self.defaultPreviewOnly = defaultPreviewOnly
        self.defaultMinConfidence = defaultMinConfidence
        updateGenre = defaultUpdateGenre
        updateYear = defaultUpdateYear
        previewOnly = defaultPreviewOnly
        minConfidence = defaultMinConfidence
    }

    // MARK: - Start Workflow

    /// Begin the update workflow for the given tracks.
    ///
    /// In **Selected Tracks** and **Smart Filter** modes, runs a dry-run first
    /// to produce proposed changes for review. In **Full Library** mode, processes
    /// all tracks through `BatchProcessor` with real-time progress.
    func start(tracks: [Track]) {
        guard canStart else { return }

        let workingTracks = applySmartFilter(to: tracks)
        totalCount = workingTracks.count
        computeScopePreview(tracks: workingTracks)

        if mode == .fullLibrary {
            startBatchProcessing(tracks: workingTracks)
        } else {
            startDryRun(tracks: workingTracks)
        }
    }

    // MARK: - Scope Preview

    /// Compute track and artist counts for the current mode/filter selection.
    func computeScopePreview(tracks: [Track]) {
        let filtered = applySmartFilter(to: tracks)
        scopeTrackCount = filtered.count
        let uniqueArtists = Set(filtered.map(\.artist))
        scopeArtistCount = uniqueArtists.count
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
                    minConfidence: confidencePercentage,
                    autoAccept: false
                )

                var allChanges: [ProposedChange] = []
                let total = tracks.count

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
                        albumTracks: [],
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

    // MARK: - Batch Processing (Full Library mode)

    private func startBatchProcessing(tracks: [Track]) {
        phase = .scanning
        processedCount = 0
        failedCount = 0
        trackStatuses = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, TrackProcessingStatus.queued) })
        currentTrackID = nil

        let options = UpdateOptions(
            updateGenre: updateGenre,
            updateYear: updateYear,
            minConfidence: confidencePercentage,
            autoAccept: true
        )

        let tracksByIndex = tracks

        processingTask = Task {
            do {
                let entries = try await batchProcessor.process(
                    tracks: tracks,
                    operation: { [updateCoordinator] track in
                        let batchResult = try await updateCoordinator.updateTracks(
                            [track],
                            options: options,
                            progressHandler: { _ in }
                        )
                        return batchResult.entries
                    },
                    progressHandler: { [weak self] update in
                        Task { @MainActor in
                            self?.handleBatchProgress(update, tracksByIndex: tracksByIndex)
                        }
                    }
                )

                finalizeBatchStatuses(for: tracksByIndex)
                completedEntries = entries
                currentTrackID = nil
                phase = .done
                progress = nil
            } catch is CancellationError {
                currentTrackID = nil
                phase = .configure
                progress = nil
            } catch let batchError as BatchProcessorError {
                currentTrackID = nil
                handleBatchError(batchError)
            } catch {
                currentTrackID = nil
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    /// Update per-track status from batch progress callbacks.
    private func handleBatchProgress(_ update: ProgressUpdate, tracksByIndex: [Track]) {
        progress = update
        processedCount = update.current

        if update.current <= tracksByIndex.count {
            let currentTrack = tracksByIndex[update.current - 1]
            currentTrackID = currentTrack.id
            trackStatuses[currentTrack.id] = .writing

            // Mark previous track as done if it was still writing
            if update.current > 1 {
                let previousTrack = tracksByIndex[update.current - 2]
                if case .writing = trackStatuses[previousTrack.id] {
                    trackStatuses[previousTrack.id] = .done
                }
            }
        }

        // On completion, mark the last writing track as done
        if update.phase == .complete, let lastTrack = tracksByIndex.last {
            if case .writing = trackStatuses[lastTrack.id] {
                trackStatuses[lastTrack.id] = .done
            }
        }
    }

    /// Mark any remaining queued tracks as skipped after batch completes.
    private func finalizeBatchStatuses(for tracks: [Track]) {
        for track in tracks {
            if case .queued = trackStatuses[track.id] {
                trackStatuses[track.id] = .skipped
            }
        }
    }

    // MARK: - Apply Accepted Changes

    /// Apply only the accepted proposed changes from the review phase.
    func applyAccepted() {
        let accepted = proposedChanges.filter(\.isAccepted)
        guard !accepted.isEmpty else { return }

        phase = .applying

        processingTask = Task {
            do {
                let tracks = accepted.map(\.track)
                let options = UpdateOptions(
                    updateGenre: updateGenre,
                    updateYear: updateYear,
                    minConfidence: confidencePercentage,
                    autoAccept: true
                )

                let batchResult = try await updateCoordinator.updateTracks(
                    tracks,
                    options: options,
                    progressHandler: { [weak self] update in
                        Task { @MainActor in
                            self?.progress = update
                        }
                    }
                )

                result = batchResult
                phase = .done
                progress = nil
            } catch {
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    // MARK: - Batch Controls

    /// Pause the batch processor (Full Library mode only).
    func pause() async {
        guard mode == .fullLibrary else { return }
        await batchProcessor.pause()
        phase = .paused
    }

    /// Resume the batch processor from paused state.
    func resume() async {
        guard mode == .fullLibrary else { return }
        await batchProcessor.resume()
        phase = .scanning
    }

    // MARK: - Change Selection

    func toggleChange(at index: Int) {
        guard proposedChanges.indices.contains(index) else { return }
        changePreviewPipeline.toggle(&proposedChanges[index])
    }

    func acceptAll() {
        changePreviewPipeline.acceptAll(&proposedChanges)
    }

    func rejectAll() {
        changePreviewPipeline.rejectAll(&proposedChanges)
    }
}

// MARK: - Lifecycle

extension WorkflowViewModel {
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        if mode == .fullLibrary {
            Task { await batchProcessor.cancel() }
        }
    }

    func updateDefaults(
        updateGenre: Bool,
        updateYear: Bool,
        previewOnly: Bool,
        minConfidence: Double
    ) {
        defaultUpdateGenre = updateGenre
        defaultUpdateYear = updateYear
        defaultPreviewOnly = previewOnly
        defaultMinConfidence = minConfidence

        guard canStart else { return }
        applyDefaultConfiguration()
    }

    func reset() {
        cancel()
        phase = .configure
        progress = nil
        proposedChanges = []
        result = nil
        completedEntries = []
        dryRunReport = nil
        processedCount = 0
        totalCount = 0
        failedCount = 0
        applyDefaultConfiguration()
        trackStatuses = [:]
        currentTrackID = nil
        scopeTrackCount = 0
        scopeArtistCount = 0
    }

    private func applyDefaultConfiguration() {
        updateGenre = defaultUpdateGenre
        updateYear = defaultUpdateYear
        previewOnly = defaultPreviewOnly
        minConfidence = defaultMinConfidence
    }
}
