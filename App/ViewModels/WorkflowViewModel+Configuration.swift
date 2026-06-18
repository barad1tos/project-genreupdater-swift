import Core
import Services

extension WorkflowViewModel {
    struct Dependencies {
        let updateCoordinator: UpdateCoordinator
        let batchProcessor: BatchProcessor
        let changePreviewPipeline: ChangePreviewPipeline
        let pendingVerificationService: (any PendingVerificationService)?
        let featureGate: FeatureGate?
        let recordProcessedTracks: (Int) -> Void
        let runMaintenancePreflight: (() async -> MaintenancePreflightResult?)?

        init(
            updateCoordinator: UpdateCoordinator,
            batchProcessor: BatchProcessor,
            changePreviewPipeline: ChangePreviewPipeline,
            pendingVerificationService: (any PendingVerificationService)? = nil,
            featureGate: FeatureGate? = nil,
            recordProcessedTracks: @escaping (Int) -> Void = { _ in
                // Default for tests/previews; production injects subscription metering.
            },
            runMaintenancePreflight: (() async -> MaintenancePreflightResult?)? = nil
        ) {
            self.updateCoordinator = updateCoordinator
            self.batchProcessor = batchProcessor
            self.changePreviewPipeline = changePreviewPipeline
            self.pendingVerificationService = pendingVerificationService
            self.featureGate = featureGate
            self.recordProcessedTracks = recordProcessedTracks
            self.runMaintenancePreflight = runMaintenancePreflight
        }
    }

    struct Defaults {
        var updateGenre = true
        var updateYear = true
        var previewOnly = true
        var minConfidence = 0.6
        var releaseYearRestoreThreshold = 5
    }
}
