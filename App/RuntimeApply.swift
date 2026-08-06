import Core
import Foundation
import Services

/// Runtime application of a saved configuration, split from the main
/// dependencies file: the synchronous head rebuilds main-actor services,
/// the awaited tail pushes the new configuration across actor boundaries.
extension AppDependencies {
    /// Legacy sync entry: the service-rebuild head runs synchronously, the
    /// actor-hop tail runs fire-and-forget. The settings command path uses
    /// `applyRuntimeConfigurationAndWait` so the result only returns once
    /// every service holds the new configuration.
    func applyRuntimeConfiguration() {
        let handoff = applyRuntimeConfigurationHead()
        Task {
            await applyRuntimeConfigurationTail(handoff)
        }
    }

    func applyRuntimeConfigurationAndWait() async {
        let handoff = applyRuntimeConfigurationHead()
        await applyRuntimeConfigurationTail(handoff)
    }

    struct RuntimeApplyHandoff {
        let pendingVerificationStore: PendingVerificationStore?
        let snapshotService: (any LibrarySnapshotService)?
        let yearDeterminator: YearDeterminator
        let apiOrchestrator: APIOrchestrator
        let runtimeConfiguration: UpdateRuntimeConfiguration
        let appleScriptConfiguration: AppleScriptConfig
        let librarySyncRuntimeConfiguration: LibrarySyncRuntimeConfiguration
        let batchProcessingConfiguration: BatchProcessingConfiguration
        let libraryPath: String
    }

    func applyRuntimeConfigurationTail(_ handoff: RuntimeApplyHandoff) async {
        try? await handoff.pendingVerificationStore?.initialize()
        await applescriptBridge?.updateConfiguration(handoff.appleScriptConfiguration)
        await applescriptBridge?.updateLibraryPath(handoff.libraryPath)
        await musicReader?.updateTestArtists(config.development.testArtists)
        await librarySyncService?.updateRuntimeConfiguration(
            handoff.librarySyncRuntimeConfiguration,
            librarySnapshotService: handoff.snapshotService,
            pendingVerificationService: handoff.pendingVerificationStore
        )
        await batchProcessor?.updateProcessingConfiguration(handoff.batchProcessingConfiguration)
        await analyticsService?.updateConfiguration(config.analytics)
        await updateCoordinator?.updateRuntimeConfiguration(
            handoff.runtimeConfiguration,
            yearDeterminator: handoff.yearDeterminator,
            apiOrchestrator: handoff.apiOrchestrator,
            librarySnapshotService: handoff.snapshotService
        )
        await updateUndoRuntimeDependencies(librarySnapshotService: handoff.snapshotService)
    }

    private func updateUndoRuntimeDependencies(
        librarySnapshotService: (any LibrarySnapshotService)?
    ) async {
        await undoCoordinator?.updateRuntimeDependencies(
            librarySnapshotService: librarySnapshotService,
            cleaning: config.cleaning
        )
    }
}
