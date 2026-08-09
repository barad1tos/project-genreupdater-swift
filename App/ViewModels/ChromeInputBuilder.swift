import Core
import Foundation
import Services

private let log = AppLogger.make(category: "chrome-input")

/// Snapshots the probed facts chrome assembly needs and publishes the
/// projection through the store (ADR 0013). Publish points live at the
/// same boundaries the other surfaces use until slice 10 moves assembly
/// behind the backend.
extension AppDependencies {
    func makeChromeInput() async -> ChromeInput {
        // Synchronous MainActor facts first, so the snapshot cannot tear
        // across the awaits below.
        let settings = ChromeSettingsFacts(
            isPreviewMode: config.runtime.dryRun,
            saveErrorMessage: configurationSaveErrorMessage,
            hasLoadFailed: configurationLoadIssue != nil
        )
        let automation = ChromeAutomationFacts(
            strategy: config.runtime.automationStrategy,
            isScheduleArmed: automationScheduleTask != nil,
            isWatchArmed: automationWatchTask != nil,
            // Cached tracker read (D6): nil = value unavailable —
            // unknown stays unknown rather than guessing due.
            isIncrementalDue: lastIncrementalRunTimestamp.map { lastRun in
                // Clamped like the auto-sync scheduler, so the chrome fact
                // and the actual cadence never diverge on a bad config.
                let interval = TimeInterval(max(1, config.runtime.incrementalIntervalMinutes)) * 60
                return lastRun.addingTimeInterval(interval) <= Date()
            }
        )
        let isRunServiceAvailable = isManualRunAvailable

        // The observer keeps this exactly as fresh as the stream; the
        // probe covers only the pre-observer bootstrap.
        var lifecycle = currentLifecycleSnapshot
        if lifecycle == nil {
            lifecycle = await currentRunLifecycle()
        }
        let recovery = await probedRecoveryFacts()
        return await ChromeInput(
            run: ChromeRunFacts(lifecycle: lifecycle, isRunServiceAvailable: isRunServiceAvailable),
            recovery: recovery,
            settings: settings,
            automation: automation,
            library: ChromeLibraryFacts(
                physicalTrackCount: probedPhysicalTrackCount(),
                scope: lifecycle?.scope
            ),
            permissions: probedChromePermissions()
        )
    }

    /// Refresh points: initialize, runtime re-apply, and after a run
    /// advances the tracker (D6) — the chrome snapshot itself stays sync.
    func refreshIncrementalRunTimestamp() async {
        lastIncrementalRunTimestamp = await incrementalRunTracker?.getLastRunTimestamp()
    }

    /// The orchestrator's cadence hook: a completed observation advances the
    /// durable mark, then chrome re-reads it so isIncrementalDue flips
    /// without waiting for the next runtime apply.
    func advanceIncrementalMark() async {
        await incrementalRunTracker?.updateLastRunTimestamp()
        await refreshIncrementalRunTimestamp()
        await refreshChromeProjection()
    }

    @discardableResult
    func refreshChromeProjection() async -> ChromeProjection {
        // Snapshot before the generation claim (the settings-slot
        // precedent): an older claimant must never carry fresher facts,
        // or the store's stale-generation guard would drop them.
        let projection = await ChromeBuilder.makeProjection(input: makeChromeInput())
        let inputGeneration = await projectionStore.nextChromeInputGeneration()
        let published = await projectionStore.replaceChromeProjection(
            projection,
            inputGeneration: inputGeneration
        )
        chrome = published
        return published
    }

    /// The write-recovery fact comes from the orchestrator — the exact
    /// in-memory gate that refuses write submissions — so chrome can
    /// never disagree with enforcement, never counts the active run's
    /// own open record, and sees hold-only and synthetic candidates.
    private func probedRecoveryFacts() async -> ChromeRecoveryFacts {
        guard let runOrchestrator else {
            return ChromeRecoveryFacts(hasUnresolvedWriteRecovery: false, recoveryRunID: nil)
        }
        let hold = await runOrchestrator.currentWriteRecoveryHold()
        return ChromeRecoveryFacts(
            hasUnresolvedWriteRecovery: hold.hasWriteBlock,
            recoveryRunID: hold.recoveryRunID
        )
    }

    /// Maps raw probe verdicts onto nullable permission facts without
    /// inference: the Music-running probe is tri-state and fails open in
    /// `status()`, so only an explicit verdict is asserted here (D7).
    private func probedChromePermissions() async -> ChromePermissions {
        let facts = await recoveryAvailability?.probedFacts()
        var musicPermission: Bool?
        if let musicReader {
            musicPermission = await musicReader.isAuthorized
        }
        return ChromePermissions(
            isMusicAppAvailable: facts?.isMusicAppRunning,
            areScriptsInstalled: facts?.areScriptsInstalled,
            isMusicPermissionGranted: musicPermission,
            isDiscogsAccessAvailable: isDiscogsAccessAvailable
        )
    }

    /// The whole-Music.app count (never the scoped mirror): probed via
    /// MusicKit only when authorization already exists, so the probe can
    /// never prompt.
    func probedPhysicalTrackCount() async -> Int? {
        guard let musicReader, await musicReader.isAuthorized else { return nil }
        do {
            return try await musicReader.trackCount()
        } catch {
            log.error("Chrome physical count probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
