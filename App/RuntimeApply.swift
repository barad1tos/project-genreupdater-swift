import Core
import Foundation
import Services

private let log = AppLogger.make(category: "runtime-apply")

/// Runtime application of a saved configuration, split from the main
/// dependencies file: the synchronous head rebuilds main-actor services,
/// the awaited tail pushes the new configuration across actor boundaries.
extension AppDependencies {
    /// Chains a runtime apply + projection publication behind any already
    /// queued apply: concurrent tails would otherwise interleave at their
    /// suspension points and push mixed service configurations.
    @discardableResult
    func enqueueRuntimeApplyAndPublish() -> Task<Void, Never> {
        let previous = runtimeApplyQueue
        let queued = Task {
            await previous?.value
            await applyRuntimeConfigurationAndWait()
            await publishSettingsProjection()
            _ = await refreshFixPlanProjection()
            _ = await republishActivityProjection()
            _ = await refreshChromeProjection()
        }
        runtimeApplyQueue = queued
        return queued
    }

    func applyRuntimeConfigurationAndWait() async {
        let handoff: RuntimeApplyHandoff
        do {
            handoff = try applyRuntimeConfigurationHead()
        } catch {
            let message = "Failed to apply runtime configuration: \(error.localizedDescription)"
            log.error("\(message, privacy: .public)")
            reportRuntimeError(message)
            return
        }
        await applyRuntimeConfigurationTail(handoff)
        // The head rebuilt the tracker; the chrome cache must follow (D6).
        await refreshIncrementalRunTimestamp()
        // Strategy or interval changes re-arm the trigger sources.
        await applyAutomationStrategy()
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
        let analytics: AnalyticsConfig
        let cleaning: CleaningConfig
        let cacheConfiguration: AppConfiguration
    }

    func applyRuntimeConfigurationTail(_ handoff: RuntimeApplyHandoff) async {
        do {
            try await handoff.pendingVerificationStore?.initialize()
        } catch {
            log.error("Pending-verification initialization failed: \(error.localizedDescription, privacy: .public)")
        }
        await cacheService?.updatePolicy(configuration: handoff.cacheConfiguration)
        await mirrorEffectDrain?.updateTargets(
            cache: cacheService,
            snapshot: handoff.snapshotService,
            projections: mirrorProjectionOutput
        )
        await drainMirrorEffectsReportingFailure()
        await applescriptBridge?.updateConfiguration(handoff.appleScriptConfiguration)
        await applescriptBridge?.updateLibraryPath(handoff.libraryPath)
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

    /// Reapplies tier-dependent runtime consumers after a subscription change.
    @discardableResult
    func handleSubscriptionTierChange() -> Bool {
        guard let featureGate else { return false }
        let tier = featureGate.currentTier
        guard tier != appliedTier else { return false }

        appliedTier = tier
        appliedCacheAccess = featureGate.canAccess(.advancedCache)
        enqueueRuntimeApplyAndPublish()
        return true
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
