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
        let currentRevision = dependencies.config.revision
        guard target.expectedSettingsRevision == currentRevision else {
            let refreshed = await dependencies.publishSettingsProjection()
            return .rejectedStale(
                message: "Settings changed elsewhere. Review the current values and retry.",
                refreshedSettings: refreshed
            )
        }

        let previousConfiguration = dependencies.config
        var accepted = configuration
        accepted.revision = currentRevision + 1
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
