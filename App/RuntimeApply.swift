import Core
import Foundation
import Services

private let log = AppLogger.make(category: "runtime-apply")

/// Runtime application of a saved configuration, split from the main
/// dependencies file: the synchronous head rebuilds main-actor services,
/// the awaited tail pushes the new configuration across actor boundaries.
extension AppDependencies {
    func applyRuntimeConfigurationAndWait() async {
        let handoff = applyRuntimeConfigurationHead()
        await applyRuntimeConfigurationTail(handoff)
    }

    /// Every configuration-derived value the tail needs, captured at head
    /// time: an in-flight tail must never observe a later `config` mutation.
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
        let testArtists: [String]
        let analytics: AnalyticsConfig
        let cleaning: CleaningConfig
    }

    func applyRuntimeConfigurationTail(_ handoff: RuntimeApplyHandoff) async {
        do {
            try await handoff.pendingVerificationStore?.initialize()
        } catch {
            log.error("Pending-verification initialization failed: \(error.localizedDescription, privacy: .public)")
        }
        await applescriptBridge?.updateConfiguration(handoff.appleScriptConfiguration)
        await applescriptBridge?.updateLibraryPath(handoff.libraryPath)
        await musicReader?.updateTestArtists(handoff.testArtists)
        await librarySyncService?.updateRuntimeConfiguration(
            handoff.librarySyncRuntimeConfiguration,
            librarySnapshotService: handoff.snapshotService,
            pendingVerificationService: handoff.pendingVerificationStore
        )
        await batchProcessor?.updateProcessingConfiguration(handoff.batchProcessingConfiguration)
        await analyticsService?.updateConfiguration(handoff.analytics)
        await updateCoordinator?.updateRuntimeConfiguration(
            handoff.runtimeConfiguration,
            yearDeterminator: handoff.yearDeterminator,
            apiOrchestrator: handoff.apiOrchestrator,
            librarySnapshotService: handoff.snapshotService
        )
        await updateUndoRuntimeDependencies(
            librarySnapshotService: handoff.snapshotService,
            cleaning: handoff.cleaning
        )
    }

    private func updateUndoRuntimeDependencies(
        librarySnapshotService: (any LibrarySnapshotService)?,
        cleaning: CleaningConfig
    ) async {
        await undoCoordinator?.updateRuntimeDependencies(
            librarySnapshotService: librarySnapshotService,
            cleaning: cleaning
        )
    }
}
