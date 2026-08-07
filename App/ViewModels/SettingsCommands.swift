import Core
import Foundation
import Services

/// The single mutation choke point for pipeline settings (ADR 0022): CAS
/// against the global settings revision, persist, runtime apply, projection
/// publication. UI surfaces build copy-with-edit values and dispatch here;
/// nothing else may write `dependencies.config`.
@MainActor
enum SettingsCommands {
    /// Fire-and-settle entry for synchronous UI contexts (bindings, button
    /// closures): the config mutates and persists BEFORE this returns, so
    /// SwiftUI reads the new value on the same render turn. Runtime apply
    /// and projection publication follow on the serialized apply queue.
    @discardableResult
    static func dispatch(
        _ configuration: AppConfiguration,
        target: SettingsCommandTarget,
        dependencies: AppDependencies
    ) -> CommandResultStatus {
        switch acceptSynchronously(configuration, target: target, dependencies: dependencies) {
        case .accepted:
            dependencies.enqueueRuntimeApplyAndPublish()
            return .accepted
        case .rejectedStale:
            Task { await dependencies.publishSettingsProjection() }
            return .rejectedStale
        case .temporaryUnavailable:
            let saveError = dependencies.configurationSaveErrorMessage ?? "Could not save the configuration."
            Task {
                await dependencies.publishSettingsProjection(saveErrorMessage: saveError)
                // Chrome carries the same persistence-health fact; a failed
                // save must reach both surfaces (ADR 0012).
                await dependencies.refreshChromeProjection()
            }
            return .temporaryUnavailable
        }
    }

    /// Awaited entry for imperative flows that consume the settled result
    /// (the JSON editor, tests): returns only after the runtime apply and
    /// both projection publications completed.
    static func apply(
        _ configuration: AppConfiguration,
        target: SettingsCommandTarget,
        dependencies: AppDependencies
    ) async -> SettingsCommandResult {
        switch acceptSynchronously(configuration, target: target, dependencies: dependencies) {
        case let .rejectedStale(message):
            let refreshed = await dependencies.publishSettingsProjection()
            return .rejectedStale(message: message, refreshedSettings: refreshed)

        case .temporaryUnavailable:
            let saveError = dependencies.configurationSaveErrorMessage ?? "Could not save the configuration."
            let refreshed = await dependencies.publishSettingsProjection(saveErrorMessage: saveError)
            await dependencies.refreshChromeProjection()
            return .temporaryUnavailable(
                message: "Could not save the configuration. Nothing was changed.",
                refreshedSettings: refreshed
            )

        case .accepted:
            await dependencies.enqueueRuntimeApplyAndPublish().value
            let refreshedSettings = await dependencies.projectionStore.currentSettings()
            let refreshedFixPlan = await dependencies.projectionStore.fixPlanProjection()
            return .accepted(
                message: "Settings saved.",
                refreshedSettings: refreshedSettings,
                refreshedFixPlan: refreshedFixPlan
            )
        }
    }

    private enum Acceptance {
        case accepted
        case rejectedStale(message: String)
        case temporaryUnavailable(message: String)
    }

    /// The shared synchronous acceptance head: CAS, overflow guard, bump,
    /// persist with in-memory rollback. No await may ever enter this path —
    /// MainActor reentrancy would break the compare-and-set otherwise.
    private static func acceptSynchronously(
        _ configuration: AppConfiguration,
        target: SettingsCommandTarget,
        dependencies: AppDependencies
    ) -> Acceptance {
        let currentRevision = dependencies.config.revision
        guard target.expectedSettingsRevision == currentRevision else {
            return .rejectedStale(message: "Settings changed elsewhere. Review the current values and retry.")
        }

        // A revision at UInt64.max can only come from a hand-edited
        // config.json; conflict instead of trapping (the FixPlanDataStore
        // corrupted-row precedent). Escalate through appState: dispatch
        // sites discard results, and this state blocks every future
        // mutation — including the reset the message recommends.
        let (bumpedRevision, overflowed) = currentRevision.addingReportingOverflow(1)
        guard !overflowed else {
            let message = "The stored settings revision is invalid. Restore or reset the configuration file."
            dependencies.reportSettingsRevisionCorruption(message)
            return .rejectedStale(message: message)
        }

        let previousConfiguration = dependencies.config
        var accepted = configuration
        accepted.revision = bumpedRevision
        dependencies.config = accepted

        guard dependencies.persistConfiguration() else {
            dependencies.config = previousConfiguration
            return .temporaryUnavailable(message: "Could not save the configuration. Nothing was changed.")
        }
        return .accepted
    }
}

extension AppDependencies {
    /// One-time UserDefaults → AppConfiguration migration (slice 7). Never
    /// runs on a failed load: seeding defaults plus the behavior would
    /// persist over the user's config.json. A persist failure keeps the
    /// key so the migration retries on the next launch (persistConfiguration
    /// clears the key on any later success, so a newer explicit choice can
    /// never be reverted by a stale key).
    func migrateDefaultUpdateBehaviorIfNeeded() {
        guard configurationLoadIssue == nil,
              let raw = UserDefaults.standard.string(forKey: AppStorageKey.defaultUpdateBehavior)
        else { return }
        config.processing.defaultUpdateBehavior = UpdateBehavior.resolved(from: raw)
        persistConfiguration()
    }

    /// The configuration-save failure message when the app is in that
    /// error state; nil otherwise.
    var configurationSaveErrorMessage: String? {
        guard case let .error(message) = appState, isConfigurationSaveIssue(appState) else {
            return nil
        }
        return message
    }

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
