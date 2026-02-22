// WorkflowViewModel.swift — Unified update workflow (replaces UpdateViewModel + BatchViewModel).

import Core
import Foundation
import Observation
import Services

// MARK: - Workflow Mode

/// Determines which tracks the workflow operates on.
enum WorkflowMode: String, CaseIterable, Identifiable, Sendable {
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
enum SmartFilterType: String, CaseIterable, Identifiable, Sendable {
    case missingGenres = "Missing Genres"
    case missingYears = "Missing Years"
    case lowConfidence = "Low Confidence"

    var id: String {
        rawValue
    }
}

// MARK: - Workflow Phase

/// Distinct stages of the unified update workflow.
enum WorkflowPhase: Sendable {
    case configure
    case scanning
    case review
    case applying
    case done
    case paused
    case error(String)
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
    var updateGenre: Bool = true
    var updateYear: Bool = true
    var previewOnly: Bool = false
    var minConfidence: Double = 0.6

    // MARK: - Phase State

    var phase: WorkflowPhase = .configure

    // MARK: - Processing State

    var progress: ProgressUpdate?
    var processedCount: Int = 0
    var totalCount: Int = 0

    // MARK: - Preview State

    var proposedChanges: [ProposedChange] = []

    // MARK: - Result State

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

    // MARK: - Dependencies

    private let updateCoordinator: UpdateCoordinator
    private let batchProcessor: BatchProcessor
    private let changePreviewPipeline: ChangePreviewPipeline

    // MARK: - Task Management

    private var processingTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        updateCoordinator: UpdateCoordinator,
        batchProcessor: BatchProcessor,
        changePreviewPipeline: ChangePreviewPipeline
    ) {
        self.updateCoordinator = updateCoordinator
        self.batchProcessor = batchProcessor
        self.changePreviewPipeline = changePreviewPipeline
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

        if mode == .fullLibrary {
            startBatchProcessing(tracks: workingTracks)
        } else {
            startDryRun(tracks: workingTracks)
        }
    }

    // MARK: - Dry Run (Selected + Smart Filter modes)

    private func startDryRun(tracks: [Track]) {
        phase = .scanning
        processedCount = 0

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
                }

                let filtered = changePreviewPipeline.filter(
                    changes: allChanges,
                    minConfidence: confidencePercentage
                )
                proposedChanges = filtered

                if previewOnly {
                    dryRunReport = DryRunReport(proposedChanges: filtered)
                }

                phase = .review
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

    // MARK: - Batch Processing (Full Library mode)

    private func startBatchProcessing(tracks: [Track]) {
        phase = .scanning
        processedCount = 0
        failedCount = 0

        let options = UpdateOptions(
            updateGenre: updateGenre,
            updateYear: updateYear,
            minConfidence: confidencePercentage,
            autoAccept: true
        )

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
                            self?.progress = update
                            self?.processedCount = update.current
                        }
                    }
                )

                completedEntries = entries
                phase = .done
                progress = nil
            } catch is CancellationError {
                phase = .configure
                progress = nil
            } catch let batchError as BatchProcessorError {
                handleBatchError(batchError)
            } catch {
                phase = .error(error.localizedDescription)
                progress = nil
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

    // MARK: - Lifecycle

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        if mode == .fullLibrary {
            Task { await batchProcessor.cancel() }
        }
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
        previewOnly = false
    }

    // MARK: - Smart Filter

    private func applySmartFilter(to tracks: [Track]) -> [Track] {
        guard mode == .smartFilter else { return tracks }
        switch smartFilterType {
        case .missingGenres:
            return tracks.filter { $0.genre == nil || $0.genre?.isEmpty == true }
        case .missingYears:
            return tracks.filter { $0.year == nil }
        case .lowConfidence:
            return tracks
        }
    }

    // MARK: - Error Handling

    private func handleBatchError(_ error: BatchProcessorError) {
        switch error {
        case let .cancelled(processedCount, _):
            self.processedCount = processedCount
            phase = .configure
        case .featureNotAvailable, .alreadyRunning, .notRunning:
            phase = .error(error.localizedDescription)
        }
        progress = nil
    }
}
