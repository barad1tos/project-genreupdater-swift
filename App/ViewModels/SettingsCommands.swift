import Core
import Foundation
import Services

/// The single mutation choke point for pipeline settings (ADR 0022): CAS
/// against the global settings revision, persist, awaited runtime apply,
/// projection publication. UI surfaces build copy-with-edit values and
/// dispatch here; nothing else may write `dependencies.config`.
@MainActor
enum SettingsCommands {
    static func apply(
        _ configuration: AppConfiguration,
        target: SettingsCommandTarget,
        dependencies: AppDependencies
    ) async -> SettingsCommandResult {
        // CAS correctness relies on the accept path staying synchronous:
        // no await may sit between the revision read here and the
        // persistConfiguration call below — MainActor reentrancy would
        // break the compare-and-set otherwise.
        let currentRevision = dependencies.config.revision
        guard target.expectedSettingsRevision == currentRevision else {
            let refreshed = await dependencies.publishSettingsProjection()
            return .rejectedStale(
                message: "Settings changed elsewhere. Review the current values and retry.",
                refreshedSettings: refreshed
            )
        }

        // A revision at UInt64.max can only come from a hand-edited
        // config.json; conflict instead of trapping (the FixPlanDataStore
        // corrupted-row precedent).
        let (bumpedRevision, overflowed) = currentRevision.addingReportingOverflow(1)
        guard !overflowed else {
            let refreshed = await dependencies.publishSettingsProjection()
            return .rejectedStale(
                message: "The stored settings revision is invalid. Restore or reset the configuration file.",
                refreshedSettings: refreshed
            )
        }

        let previousConfiguration = dependencies.config
        var accepted = configuration
        accepted.revision = bumpedRevision
        dependencies.config = accepted

        guard dependencies.persistConfiguration() else {
            dependencies.config = previousConfiguration
            let refreshed = await dependencies.publishSettingsProjection(
                saveErrorMessage: dependencies.configurationSaveErrorMessage
                    ?? "Could not save the configuration."
            )
            return .temporaryUnavailable(
                message: "Could not save the configuration. Nothing was changed.",
                refreshedSettings: refreshed
            )
        }

        await dependencies.applyRuntimeConfigurationAndWait()
        let refreshedSettings = await dependencies.publishSettingsProjection()
        // Always refresh: the fix-plan staleness evaluation decides whether
        // this change matters, and the projection store dedups identical
        // results — presentation-only changes cause no revision bump.
        let refreshedFixPlan = await dependencies.refreshFixPlanProjection()
        return .accepted(
            message: "Settings saved.",
            refreshedSettings: refreshedSettings,
            refreshedFixPlan: refreshedFixPlan
        )
    }
}

extension AppDependencies {
    /// Publishes the current configuration as the settings projection; the
    /// settings command path is the only writer, so the projection always
    /// reflects the last accepted (or rolled-back) state.
    @discardableResult
    func publishSettingsProjection(saveErrorMessage: String? = nil) async -> SettingsProjection {
        // Snapshot before the generation claim's suspension: a publisher
        // holding an older generation must never carry a newer config, or
        // the store's stale-generation guard would drop the fresher state.
        let projection = SettingsProjection(
            revision: .initial,
            settingsRevision: config.revision,
            configuration: config,
            saveErrorMessage: saveErrorMessage
        )
        let inputGeneration = await projectionStore.nextSettingsInputGeneration()
        return await projectionStore.replaceSettingsProjection(
            projection,
            inputGeneration: inputGeneration
        )
    }
}
