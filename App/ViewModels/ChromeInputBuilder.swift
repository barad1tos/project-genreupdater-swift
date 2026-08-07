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
            isAutoSyncRunning: isAutoSyncRunning,
            // No cheap due-probe exists yet; unknown stays unknown (D7).
            isIncrementalDue: nil
        )
        let isRunServiceAvailable = isManualRunAvailable

        let lifecycle = await currentRunLifecycle()
        let recovery = await probedRecoveryFacts()
        let fixPlan = await projectionStore.fixPlanProjection()
        return await ChromeInput(
            run: ChromeRunFacts(lifecycle: lifecycle, isRunServiceAvailable: isRunServiceAvailable),
            recovery: recovery,
            settings: settings,
            automation: automation,
            library: ChromeLibraryFacts(
                physicalTrackCount: probedPhysicalTrackCount(),
                scope: lifecycle?.scope
            ),
            permissions: probedChromePermissions(),
            hasReviewableFixPlan: fixPlan.status == .ready || fixPlan.status == .stale
        )
    }

    @discardableResult
    func refreshChromeProjection() async -> ChromeProjection {
        // Snapshot before the generation claim (the settings-slot
        // precedent): an older claimant must never carry fresher facts,
        // or the store's stale-generation guard would drop them.
        let projection = await ChromeBuilder.makeProjection(input: makeChromeInput())
        let inputGeneration = await projectionStore.nextChromeInputGeneration()
        return await projectionStore.replaceChromeProjection(
            projection,
            inputGeneration: inputGeneration
        )
    }

    /// The write-recovery fact comes from the run store — the DB-level
    /// truth — not from the reports projection, whose refresh cadence is
    /// a UI concern and which is empty before the first screen loads.
    private func probedRecoveryFacts() async -> ChromeRecoveryFacts {
        guard let runRecordStore else {
            return ChromeRecoveryFacts(hasUnresolvedWriteRecovery: false, recoveryRunID: nil)
        }
        do {
            let page = try await runRecordStore.recoveryRecords()
            return ChromeRecoveryFacts(
                hasUnresolvedWriteRecovery: !page.records.isEmpty,
                recoveryRunID: page.records.first?.runID
            )
        } catch {
            log.error("Chrome recovery probe failed: \(error.localizedDescription, privacy: .public)")
            return ChromeRecoveryFacts(hasUnresolvedWriteRecovery: false, recoveryRunID: nil)
        }
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
    private func probedPhysicalTrackCount() async -> Int? {
        guard let musicReader, await musicReader.isAuthorized else { return nil }
        do {
            return try await musicReader.trackCount()
        } catch {
            log.error("Chrome physical count probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
