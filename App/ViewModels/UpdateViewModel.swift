import Core
import Foundation
import Observation
import Services

// MARK: - Update Phase

/// Distinct stages of the update workflow visible to the user.
enum UpdatePhase: Sendable {
    case configuring
    case processing
    case preview
    case applying
    case done
    case dryRunSummary
}

// MARK: - Update View Model

/// Drives the update workflow: configure options, dry-run preview, then apply.
///
/// Coordinates between `UpdateCoordinator` (single/batch updates) and
/// `ChangePreviewPipeline` (filtering, acceptance toggling) to present
/// a staged review flow for track metadata changes.
@Observable @MainActor
final class UpdateViewModel {
    // MARK: - Configuration State

    var phase: UpdatePhase = .configuring
    var updateGenre: Bool = true
    var updateYear: Bool = true

    /// When true, analysis results are shown as a read-only summary
    /// without offering the option to apply changes.
    var previewOnly: Bool = false

    /// Confidence threshold as a slider value (0.0 to 1.0).
    /// Converted to an integer percentage (0-100) when passed to Services.
    var minConfidence: Double = 0.6

    // MARK: - Processing State

    var progress: ProgressUpdate?

    // MARK: - Preview State

    var proposedChanges: [ProposedChange] = []

    // MARK: - Result State

    var result: BatchUpdateResult?
    var dryRunReport: DryRunReport?
    var errorMessage: String?

    // MARK: - Computed Properties

    var acceptedCount: Int {
        proposedChanges.filter(\.isAccepted).count
    }

    var confidencePercentage: Int {
        Int(minConfidence * 100)
    }

    // MARK: - Dependencies

    private let updateCoordinator: UpdateCoordinator
    private let changePreviewPipeline: ChangePreviewPipeline

    // MARK: - Task Management

    private var processingTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        updateCoordinator: UpdateCoordinator,
        changePreviewPipeline: ChangePreviewPipeline
    ) {
        self.updateCoordinator = updateCoordinator
        self.changePreviewPipeline = changePreviewPipeline
    }

    // MARK: - Dry Run

    /// Start a dry-run analysis that produces proposed changes for user review.
    ///
    /// Each track is processed individually through `UpdateCoordinator.updateTrack`
    /// in dry-run mode. Results are filtered by the current confidence threshold
    /// before transitioning to the `.preview` phase.
    ///
    /// - Parameter tracks: The tracks to analyze for potential metadata updates.
    func startDryRun(tracks: [Track]) {
        phase = .processing
        errorMessage = nil

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
                    dryRunReport = DryRunReport(
                        proposedChanges: filtered
                    )
                    phase = .dryRunSummary
                } else {
                    phase = .preview
                }
                progress = nil
            } catch is CancellationError {
                phase = .configuring
                progress = nil
            } catch {
                errorMessage = error.localizedDescription
                phase = .configuring
                progress = nil
            }
        }
    }

    // MARK: - Apply Changes

    /// Apply only the accepted proposed changes to Music.app.
    ///
    /// Transitions to `.applying` during the write, then `.done` on success.
    /// Falls back to `.preview` if an error occurs so the user can retry.
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
                errorMessage = error.localizedDescription
                phase = .preview
                progress = nil
            }
        }
    }

    // MARK: - Change Selection

    /// Toggle acceptance of a single proposed change by index.
    func toggleChange(at index: Int) {
        guard proposedChanges.indices.contains(index) else { return }
        changePreviewPipeline.toggle(&proposedChanges[index])
    }

    /// Mark all proposed changes as accepted.
    func acceptAll() {
        changePreviewPipeline.acceptAll(&proposedChanges)
    }

    /// Mark all proposed changes as rejected.
    func rejectAll() {
        changePreviewPipeline.rejectAll(&proposedChanges)
    }

    // MARK: - Lifecycle

    /// Cancel any in-progress processing task.
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
    }

    /// Reset the view model to its initial configuring state.
    func reset() {
        cancel()
        phase = .configuring
        progress = nil
        proposedChanges = []
        result = nil
        dryRunReport = nil
        previewOnly = false
        errorMessage = nil
    }
}
