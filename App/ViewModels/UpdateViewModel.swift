import Core
import Foundation
import Observation
import Services

// MARK: - Update Phase

/// Distinct stages of the update workflow visible to the user.
enum UpdatePhase {
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
    var updateGenre: Bool
    var updateYear: Bool
    var forceYearLookup = false
    var cleanTrackNames = false
    var cleanAlbumNames = false

    /// When true, analysis results are shown as a read-only summary
    /// without offering the option to apply changes.
    var previewOnly: Bool

    /// Confidence threshold as a slider value (0.0 to 1.0).
    /// Converted to an integer percentage (0-100) when passed to Services.
    var minConfidence: Double

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

    var hasEnabledOperation: Bool {
        updateGenre || updateYear || cleanTrackNames || cleanAlbumNames
    }

    var confidencePercentage: Int {
        UpdateOptions.clampedConfidencePercent(fromRatio: minConfidence)
    }

    // MARK: - Dependencies

    private let updateCoordinator: UpdateCoordinator
    private let changePreviewPipeline: ChangePreviewPipeline
    private let featureGate: FeatureGate?
    private let recordProcessedTracks: (Int) -> Void
    private let defaultUpdateGenre: Bool
    private let defaultUpdateYear: Bool
    private let defaultPreviewOnly: Bool
    private let defaultMinConfidence: Double

    // MARK: - Task Management

    private var processingTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        updateCoordinator: UpdateCoordinator,
        changePreviewPipeline: ChangePreviewPipeline,
        featureGate: FeatureGate? = nil,
        recordProcessedTracks: @escaping (Int) -> Void = { _ in },
        defaultUpdateGenre: Bool = true,
        defaultUpdateYear: Bool = true,
        defaultPreviewOnly: Bool = false,
        defaultMinConfidence: Double = 0.6
    ) {
        self.updateCoordinator = updateCoordinator
        self.changePreviewPipeline = changePreviewPipeline
        self.featureGate = featureGate
        self.recordProcessedTracks = recordProcessedTracks
        self.defaultUpdateGenre = defaultUpdateGenre
        self.defaultUpdateYear = defaultUpdateYear
        self.defaultPreviewOnly = defaultPreviewOnly
        self.defaultMinConfidence = defaultMinConfidence
        updateGenre = defaultUpdateGenre
        updateYear = defaultUpdateYear
        previewOnly = defaultPreviewOnly
        minConfidence = defaultMinConfidence
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
        do {
            _ = try featureGate?.requireTrackCapacity(for: tracks)
        } catch {
            errorMessage = error.localizedDescription
            phase = .configuring
            return
        }

        phase = .processing
        errorMessage = nil

        processingTask = Task {
            do {
                let options = UpdateOptions(
                    updateGenre: updateGenre,
                    updateYear: updateYear,
                    forceYearLookup: forceYearLookup,
                    cleanTrackNames: cleanTrackNames,
                    cleanAlbumNames: cleanAlbumNames,
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

                    do {
                        let changes = try await previewChanges(for: track, options: options)
                        allChanges.append(contentsOf: changes)
                    } catch let error where Self.isWriteEligibilityError(error) {
                        continue
                    }
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

    private func previewChanges(
        for track: Track,
        options: UpdateOptions
    ) async throws -> [ProposedChange] {
        try await updateCoordinator.updateTrack(
            track,
            albumTracks: [],
            options: options,
            dryRun: true
        )
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
                let batchResult = try await updateCoordinator.applyAcceptedChanges(
                    accepted,
                    progressHandler: { [weak self] update in
                        Task { @MainActor in
                            self?.progress = update
                        }
                    }
                )

                result = batchResult
                recordAppliedTrackUsage(from: batchResult)
                phase = .done
                progress = nil
            } catch {
                errorMessage = error.localizedDescription
                phase = .preview
                progress = nil
            }
        }
    }

    private func recordAppliedTrackUsage(from result: BatchUpdateResult) {
        let appliedTrackCount = Set(result.entries.map(\.trackID)).count
        guard appliedTrackCount > 0 else { return }
        recordProcessedTracks(appliedTrackCount)
    }

    private static func isWriteEligibilityError(_ error: any Error) -> Bool {
        switch error {
        case UpdateCoordinatorError.trackNotEditable, UpdateCoordinatorError.missingAppleScriptID:
            true
        default:
            false
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
        updateGenre = defaultUpdateGenre
        updateYear = defaultUpdateYear
        forceYearLookup = false
        cleanTrackNames = false
        cleanAlbumNames = false
        previewOnly = defaultPreviewOnly
        minConfidence = defaultMinConfidence
        errorMessage = nil
    }
}
