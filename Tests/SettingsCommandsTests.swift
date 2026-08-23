import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Settings commands")
@MainActor
struct SettingsCommandsTests {
    @Test("an accepted command bumps the revision, persists and publishes")
    func acceptBumpsPersistsPublishes() async {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { saved.append($0) }
        )
        var edited = dependencies.config
        edited.development.testArtists = ["Clutch"]
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(dependencies.config.revision == 1)
        #expect(dependencies.config.development.testArtists == ["Clutch"])
        #expect(saved.configurations.last?.revision == 1)
        #expect(result.refreshedSettings.settingsRevision == 1)
        #expect(result.refreshedFixPlan != nil)
    }

    @Test("a stale expected revision rejects without any mutation")
    func staleExpectedRevisionRejects() async {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { saved.append($0) }
        )
        var edited = dependencies.config
        edited.development.testArtists = ["Clutch"]
        let target = SettingsCommandTarget(expectedSettingsRevision: 9)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .rejectedStale)
        #expect(dependencies.config.revision == 0)
        #expect(dependencies.config.development.testArtists.isEmpty)
        #expect(saved.configurations.isEmpty)
        #expect(result.refreshedSettings.settingsRevision == 0)
    }

    @Test("a save failure rolls back and reports through the projection")
    func saveFailureRollsBackAndReports() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in throw SaveProbeFailure() }
        )
        var edited = dependencies.config
        edited.development.testArtists = ["Clutch"]
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .temporaryUnavailable)
        #expect(dependencies.config.revision == 0)
        #expect(dependencies.config.development.testArtists.isEmpty)
        #expect(result.refreshedSettings.saveErrorMessage != nil)
    }

    @Test("invalid settings are rejected with actionable field details")
    func rejectsInvalidSettings() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { try $0.validate() }
        )
        var edited = dependencies.config
        edited.genreUpdate.batchSize = 0
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .rejectedInvalid)
        #expect(result.message.contains("genreUpdate.batchSize"))
        #expect(result.message.contains("must be at least 1"))
        #expect(dependencies.config.genreUpdate.batchSize > 0)
        #expect(result.refreshedSettings.saveErrorMessage?.contains("genreUpdate.batchSize") == true)
    }

    @Test("non-finite settings are invalid rather than unavailable")
    func rejectsNonFiniteSettings() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { try $0.validate() }
        )
        var edited = dependencies.config
        edited.analytics.durationThresholds.shortMax = .nan
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .rejectedInvalid)
        #expect(result.message.contains("analytics.durationThresholds.shortMax"))
        #expect(result.message.contains("must be finite"))
    }

    @Test("conflicting artist mappings roll back with actionable source keys")
    func rejectsArtistConflicts() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { try $0.validate() }
        )
        var edited = dependencies.config
        edited.artistRenamer.mappings = [
            " oldartist  ": "Second",
            "OldArtist": "First",
        ]
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .rejectedInvalid)
        #expect(result.message.contains(#"" oldartist  ""#))
        #expect(result.message.contains(#""OldArtist""#))
        #expect(dependencies.config.artistRenamer.mappings.isEmpty)
        #expect(result.refreshedSettings.saveErrorMessage?.contains("artistRenamer.mappings") == true)
    }

    @Test("after a rolled-back failure the original revision still accepts")
    func rolledBackFailureKeepsRevisionUsable() async {
        let saved = SavedConfigurations()
        let gate = FailureGate()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { configuration in
                if gate.shouldFail() {
                    throw SaveProbeFailure()
                }
                saved.append(configuration)
            }
        )
        var edited = dependencies.config
        edited.development.testArtists = ["Clutch"]
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        _ = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)
        let retry = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(retry.status == .accepted)
        #expect(dependencies.config.revision == 1)
        #expect(saved.configurations.count == 1)
    }

    @Test("sequential mutations compose through the command dispatcher")
    func sequentialMutationsCompose() {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { saved.append($0) }
        )

        mutateConfiguration(dependencies) { $0.development.testArtists = ["Clutch"] }
        let second = mutateConfiguration(dependencies) { $0.runtime.dryRun.toggle() }

        #expect(second == .accepted)
        #expect(dependencies.config.revision == 2)
        #expect(dependencies.config.development.testArtists == ["Clutch"])
    }

    @Test("the dispatcher mutates and persists before returning")
    func dispatchMutatesSynchronously() {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { saved.append($0) }
        )

        let status = mutateConfiguration(dependencies) { $0.development.testArtists = ["Clutch"] }

        // No await happened: SwiftUI reads the new value on this same turn
        // (controlled TextField bindings depend on it).
        #expect(status == .accepted)
        #expect(dependencies.config.development.testArtists == ["Clutch"])
        #expect(saved.configurations.count == 1)
    }

    @Test("Zero verification intervals display Off with actionable consequences")
    func zeroIntervalsExplainManualFallbacks() {
        #expect(VerificationScheduleRange.days.contains(0))
        #expect(VerificationScheduleRange.days.contains(90))
        #expect(!VerificationScheduleRange.days.contains(-1))
        #expect(!VerificationScheduleRange.days.contains(91))
        #expect(VerificationSettingsSection.intervalText(days: 0) == "Off")
        #expect(VerificationSettingsSection.intervalText(days: 7) == "7d")
        #expect(VerificationSettingsSection.disabledMessages(databaseDays: 7, pendingDays: 14).isEmpty)
        #expect(VerificationSettingsSection.disabledMessages(databaseDays: 0, pendingDays: 14) == [
            "Automatic database cleanup is off. Verify Now still works.",
        ])
        #expect(VerificationSettingsSection.disabledMessages(databaseDays: 7, pendingDays: 0) == [
            "Automatic pending-year retries are off. Run Pending Verification manually.",
        ])
    }

    @Test("a whole-config command discards the submitted revision")
    func wholeConfigCommandDiscardsSubmittedRevision() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this revision pin.
            }
        )
        var submitted = dependencies.config
        submitted.revision = 999
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(submitted, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(dependencies.config.revision == 1)
    }

    @Test("a revision at the UInt64 maximum requires attention")
    func maxRevisionRequiresAttention() async {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: {
                var configuration = AppConfiguration()
                configuration.revision = .max
                return configuration
            },
            configurationSaver: { saved.append($0) }
        )
        let target = SettingsCommandTarget(expectedSettingsRevision: .max)

        let result = await SettingsCommands.apply(dependencies.config, target: target, dependencies: dependencies)

        #expect(result.status == .requiresAttention)
        #expect(result.message.contains(AppConfiguration.configFileURL.path))
        #expect(result.message.contains("set \"revision\" to 0"))
        #expect(result.message.contains("relaunch GenreUpdater"))
        #expect(result.message.localizedCaseInsensitiveContains("reset") == false)
        #expect(dependencies.config.revision == .max)
        #expect(saved.configurations.isEmpty)
        // Corrupted persistence blocks every in-app mutation, so recovery
        // must direct the user to the persisted file instead of offering retry.
        #expect(isErrorState(dependencies.appState))
    }

    @Test("a fingerprint-relevant change marks the current plan stale")
    func fingerprintChangeMarksPlanStale() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this staleness pin.
            }
        )
        // Settle runtime side effects (discogs availability) with one
        // accepted no-diff cycle before capturing the plan's baseline.
        // Test-only artifact: these dependencies never ran initialize(),
        // which probes discogs availability at launch in production.
        _ = await SettingsCommands.apply(
            dependencies.config,
            target: SettingsCommandTarget(expectedSettingsRevision: 0),
            dependencies: dependencies
        )
        let planConfig = dependencies.capturePreviewConfig(
            at: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: dependencies.isDiscogsAccessAvailable ?? false
        )
        let plan = makeSettingsProbePlan(configuration: planConfig)
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: MemoryFixPlanStore(plan: plan, decision: decision)
        )
        let baseline = await dependencies.refreshFixPlanProjection()
        #expect(baseline.stalenessReasons.isEmpty)
        var edited = dependencies.config
        edited.cleaning.editionMarkers.append("Deluxe Probe Edition")
        let target = SettingsCommandTarget(expectedSettingsRevision: 1)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(result.refreshedFixPlan?.stalenessReasons.contains(.configurationChanged) == true)
    }

    @Test("a presentation-only change leaves the plan projection untouched")
    func presentationChangeLeavesPlanUntouched() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this staleness pin.
            }
        )
        // Settle runtime side effects (discogs availability) with one
        // accepted no-diff cycle before capturing the plan's baseline.
        // Test-only artifact: these dependencies never ran initialize(),
        // which probes discogs availability at launch in production.
        _ = await SettingsCommands.apply(
            dependencies.config,
            target: SettingsCommandTarget(expectedSettingsRevision: 0),
            dependencies: dependencies
        )
        let planConfig = dependencies.capturePreviewConfig(
            at: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: dependencies.isDiscogsAccessAvailable ?? false
        )
        let plan = makeSettingsProbePlan(configuration: planConfig)
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: MemoryFixPlanStore(plan: plan, decision: decision)
        )
        let baseline = await dependencies.refreshFixPlanProjection()
        #expect(baseline.stalenessReasons.isEmpty)
        var edited = dependencies.config
        edited.analytics.enabled.toggle()
        let target = SettingsCommandTarget(expectedSettingsRevision: 1)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(result.refreshedFixPlan?.stalenessReasons.isEmpty == true)
        #expect(result.refreshedFixPlan?.revision == baseline.revision)
    }

    @Test("a stored UserDefaults behavior migrates into the configuration once")
    func userDefaultsBehaviorMigratesOnce() {
        let defaults = UserDefaults.standard
        // Clear residue from an interrupted earlier run before seeding.
        defaults.removeObject(forKey: AppStorageKey.defaultUpdateBehavior)
        defaults.set("genre_only", forKey: AppStorageKey.defaultUpdateBehavior)
        defer { defaults.removeObject(forKey: AppStorageKey.defaultUpdateBehavior) }
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { saved.append($0) }
        )

        dependencies.migrateDefaultUpdateBehaviorIfNeeded()

        #expect(dependencies.config.processing.defaultUpdateBehavior == .genreOnly)
        #expect(defaults.string(forKey: AppStorageKey.defaultUpdateBehavior) == nil)
        #expect(saved.configurations.count == 1)
    }

    @Test("the behavior migration never runs on a failed configuration load")
    func behaviorMigrationSkipsFailedLoad() {
        let defaults = UserDefaults.standard
        // Clear residue from an interrupted earlier run before seeding.
        defaults.removeObject(forKey: AppStorageKey.defaultUpdateBehavior)
        defaults.set("genre_only", forKey: AppStorageKey.defaultUpdateBehavior)
        defer { defaults.removeObject(forKey: AppStorageKey.defaultUpdateBehavior) }
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { throw SaveProbeFailure() },
            configurationSaver: { saved.append($0) }
        )

        dependencies.migrateDefaultUpdateBehaviorIfNeeded()

        #expect(saved.configurations.isEmpty)
        #expect(defaults.string(forKey: AppStorageKey.defaultUpdateBehavior) == "genre_only")
    }

    @Test("a failed load never persists until a command repairs it")
    func explicitCommandRepairsFailedLoad() async {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { throw SaveProbeFailure() },
            configurationSaver: { saved.append($0) }
        )
        #expect(dependencies.configurationLoadIssue != nil)
        let target = SettingsCommandTarget(expectedSettingsRevision: 0)

        let result = await SettingsCommands.apply(dependencies.config, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(saved.configurations.count == 1)
        #expect(dependencies.configurationLoadIssue == nil)
    }

    @Test("initialization bootstraps the settings projection with the loaded configuration")
    func initializeBootstrapsSettingsProjection() async {
        let dependencies = AppDependencies(
            configurationLoader: {
                var configuration = AppConfiguration()
                configuration.development.testArtists = ["Bootstrap Probe"]
                return configuration
            },
            configurationSaver: { _ in
                // Persistence is irrelevant to this bootstrap pin.
            }
        )

        // The bootstrap publish precedes service initialization, so the
        // pin holds regardless of how far initialize() gets afterwards.
        await dependencies.initialize()
        let current = await dependencies.projectionStore.currentSettings()

        #expect(current.configuration.development.testArtists == ["Bootstrap Probe"])
    }
}

@MainActor
private func isErrorState(_ state: AppState) -> Bool {
    guard case .error = state else {
        return false
    }
    return true
}

@MainActor
private final class SavedConfigurations {
    private(set) var configurations: [AppConfiguration] = []

    nonisolated init() { /* no setup: storage starts empty */ }

    func append(_ configuration: AppConfiguration) {
        configurations.append(configuration)
    }
}

private final class FailureGate: @unchecked Sendable {
    private var hasFailed = false

    func shouldFail() -> Bool {
        defer { hasFailed = true }
        return !hasFailed
    }
}

private struct SaveProbeFailure: Error {}

@MainActor
private func makeSettingsProbePlan(configuration: FixPlanConfig) -> FixPlan {
    let item = makeCommandItem(id: "00000000-0000-0000-0000-000000000901", type: .genreUpdate)
    return FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: Date(timeIntervalSince1970: 100),
        configuration: configuration,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "settings-command-test"
        ),
        items: [item]
    )
}
