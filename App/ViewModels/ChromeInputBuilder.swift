import Core
import Foundation
import Services

/// Snapshots the probed facts chrome assembly needs and publishes the
/// projection through the store (ADR 0013). Publish points live at the
/// same boundaries the other surfaces use until slice 10 moves assembly
/// behind the backend.
extension AppDependencies {
    func makeChromeInput() async -> ChromeInput {
        let lifecycle = await currentRunLifecycle()
        let reports = await projectionStore.reportsProjection()
        let fixPlan = await projectionStore.fixPlanProjection()
        let availability = await recoveryAvailability?.status()
        let physicalTrackCount = await probedTrackCount()
        return ChromeInput(
            lifecycle: lifecycle,
            hasUnresolvedWriteRecovery: !reports.recoveryRunIDs.isEmpty,
            recoveryRunID: reports.recoveryRunIDs.first
                .flatMap(UUID.init(uuidString:))
                .map(RunID.init(rawValue:)),
            isPreviewMode: config.runtime.dryRun,
            isAutoSyncRunning: isAutoSyncRunning,
            // No cheap due-probe exists yet; unknown stays unknown (D7).
            isIncrementalDue: nil,
            physicalTrackCount: physicalTrackCount,
            scope: lifecycle?.scope,
            permissions: makeChromePermissions(availability: availability),
            settingsSaveErrorMessage: configurationSaveErrorMessage,
            settingsLoadFailed: configurationLoadIssue != nil,
            isRunServiceAvailable: isManualRunAvailable,
            hasReviewableFixPlan: fixPlan.status == .ready
        )
    }

    @discardableResult
    func refreshChromeProjection() async -> ChromeProjection {
        let inputGeneration = await projectionStore.nextChromeInputGeneration()
        let projection = await ChromeBuilder.makeProjection(input: makeChromeInput())
        return await projectionStore.replaceChromeProjection(
            projection,
            inputGeneration: inputGeneration
        )
    }

    /// Maps the recovery preflight probe onto nullable permission facts:
    /// the probe checks Music.app first, so a scripts verdict proves the
    /// Music check passed, while a Music verdict leaves scripts unprobed.
    private func makeChromePermissions(availability: RecoveryAvailabilityStatus?) -> ChromePermissions {
        var permissions = ChromePermissions(isDiscogsAccessAvailable: isDiscogsAccessAvailable)
        switch availability {
        case .available:
            permissions = ChromePermissions(
                isMusicAppAvailable: true,
                areScriptsInstalled: true,
                isDiscogsAccessAvailable: permissions.isDiscogsAccessAvailable
            )
        case .blocked(.musicAppUnavailable):
            permissions = ChromePermissions(
                isMusicAppAvailable: false,
                isDiscogsAccessAvailable: permissions.isDiscogsAccessAvailable
            )
        case .blocked(.scriptsUnavailable):
            permissions = ChromePermissions(
                isMusicAppAvailable: true,
                areScriptsInstalled: false,
                isDiscogsAccessAvailable: permissions.isDiscogsAccessAvailable
            )
        case .blocked(.storeUnavailable), nil:
            break
        }
        return permissions
    }

    private func probedTrackCount() async -> Int? {
        guard let trackStore else { return nil }
        return try? await trackStore.trackCount()
    }
}
