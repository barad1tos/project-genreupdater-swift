import Core
import Foundation
import Observation
import Services

// MARK: - Batch State

/// Processing states for the batch workflow.
enum BatchState: Sendable {
    case idle
    case running
    case paused
    case completed
    case cancelled
    case error(String)
}

// MARK: - Batch View Model

/// Drives the batch-processing workflow: start, pause, resume, cancel.
///
/// Coordinates `BatchProcessor` (sequencing, checkpointing, pause/resume)
/// with `UpdateCoordinator` (per-track determination and writes) to process
/// large track collections with real-time progress reporting.
@Observable @MainActor
final class BatchViewModel {
    // MARK: - Configuration

    var updateGenre: Bool = true
    var updateYear: Bool = true

    /// Confidence threshold as a slider value (0.0 to 1.0).
    /// Converted to an integer percentage (0-100) when passed to Services.
    var minConfidence: Double = 0.6

    // MARK: - Processing State

    var state: BatchState = .idle
    var progress: ProgressUpdate?
    var processedCount: Int = 0
    var failedCount: Int = 0
    var changes: [ChangeLogEntry] = []
    var errorMessage: String?

    // MARK: - Computed Properties

    var confidencePercentage: Int {
        Int(minConfidence * 100)
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    var canStart: Bool {
        switch state {
        case .idle, .completed, .cancelled, .error:
            true
        case .running, .paused:
            false
        }
    }

    // MARK: - Dependencies

    private let batchProcessor: BatchProcessor
    private let updateCoordinator: UpdateCoordinator

    // MARK: - Task Management

    private var processingTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        batchProcessor: BatchProcessor,
        updateCoordinator: UpdateCoordinator
    ) {
        self.batchProcessor = batchProcessor
        self.updateCoordinator = updateCoordinator
    }

    // MARK: - Start Processing

    /// Begin batch processing for the given tracks.
    ///
    /// Creates a `Task` that feeds each track through `BatchProcessor.process()`,
    /// using `UpdateCoordinator.updateTracks` as the per-track operation. Progress
    /// updates are bridged from the Sendable handler to the MainActor for UI binding.
    ///
    /// - Parameters:
    ///   - tracks: The tracks to process in batch.
    ///   - resumeBatchID: Optional batch ID to resume from a previous checkpoint.
    func start(tracks: [Track], resumeBatchID: UUID? = nil) {
        guard canStart else { return }

        state = .running
        errorMessage = nil
        processedCount = 0
        failedCount = 0
        changes = []

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
                    resumeBatchID: resumeBatchID,
                    operation: { [updateCoordinator] track in
                        let result = try await updateCoordinator.updateTracks(
                            [track],
                            options: options,
                            progressHandler: { _ in }
                        )
                        return result.entries
                    },
                    progressHandler: { [weak self] update in
                        Task { @MainActor in
                            self?.progress = update
                            self?.processedCount = update.current
                        }
                    }
                )

                changes = entries
                state = .completed
            } catch is CancellationError {
                state = .cancelled
            } catch let error as BatchProcessorError {
                handleBatchError(error)
            } catch {
                errorMessage = error.localizedDescription
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Controls

    /// Pause the batch processor after the current track finishes.
    func pause() async {
        await batchProcessor.pause()
        state = .paused
    }

    /// Resume the batch processor from a paused state.
    func resume() async {
        await batchProcessor.resume()
        state = .running
    }

    /// Cancel batch processing and discard the in-flight task.
    func cancel() async {
        await batchProcessor.cancel()
        processingTask?.cancel()
        state = .cancelled
    }

    // MARK: - Lifecycle

    /// Reset the view model to its initial idle state.
    func reset() {
        processingTask?.cancel()
        processingTask = nil
        state = .idle
        progress = nil
        processedCount = 0
        failedCount = 0
        changes = []
        errorMessage = nil
    }

    // MARK: - Error Handling

    private func handleBatchError(_ error: BatchProcessorError) {
        switch error {
        case let .cancelled(processedCount, _):
            self.processedCount = processedCount
            state = .cancelled
        case .featureNotAvailable, .alreadyRunning, .notRunning:
            errorMessage = error.localizedDescription
            state = .error(error.localizedDescription)
        }
    }
}
