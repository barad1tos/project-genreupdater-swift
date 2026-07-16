import Core
import Foundation
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
        let ensureRecoveryHold: () async -> Bool
        let clearRecovery: (UUID) async throws -> Void
        let prepareMutationMetadata: (([Track]) async throws -> Void)?
        let resolveIncrementalTracks: ([Track], IncrementalTrackScopeOptions) async -> [Track]
        let invalidateAlbumYearCache: (() async -> Void)?
        let updateIncrementalRunTimestamp: (() async -> Void)?
        let problematicAlbumReportMinAttempts: () -> Int

        init(
            updateCoordinator: UpdateCoordinator,
            batchProcessor: BatchProcessor,
            changePreviewPipeline: ChangePreviewPipeline,
            pendingVerificationService: (any PendingVerificationService)? = nil,
            featureGate: FeatureGate? = nil,
            recordProcessedTracks: @escaping (Int) -> Void = { _ in
                // Default for tests/previews; production injects subscription metering.
            },
            runMaintenancePreflight: (() async -> MaintenancePreflightResult?)? = nil,
            ensureRecoveryHold: @escaping () async -> Bool = { false },
            clearRecovery: @escaping (UUID) async throws -> Void,
            prepareMutationMetadata: (([Track]) async throws -> Void)? = nil,
            resolveIncrementalTracks: @escaping (
                [Track],
                IncrementalTrackScopeOptions
            ) async -> [Track] = { tracks, _ in tracks },
            invalidateAlbumYearCache: (() async -> Void)? = nil,
            updateIncrementalRunTimestamp: (() async -> Void)? = nil,
            problematicAlbumReportMinAttempts: @escaping () -> Int = { 3 }
        ) {
            self.updateCoordinator = updateCoordinator
            self.batchProcessor = batchProcessor
            self.changePreviewPipeline = changePreviewPipeline
            self.pendingVerificationService = pendingVerificationService
            self.featureGate = featureGate
            self.recordProcessedTracks = recordProcessedTracks
            self.runMaintenancePreflight = runMaintenancePreflight
            self.ensureRecoveryHold = ensureRecoveryHold
            self.clearRecovery = clearRecovery
            self.prepareMutationMetadata = prepareMutationMetadata
            self.resolveIncrementalTracks = resolveIncrementalTracks
            self.invalidateAlbumYearCache = invalidateAlbumYearCache
            self.updateIncrementalRunTimestamp = updateIncrementalRunTimestamp
            self.problematicAlbumReportMinAttempts = problematicAlbumReportMinAttempts
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
