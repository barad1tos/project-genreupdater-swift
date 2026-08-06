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
        let target = SettingsCommandTarget(expectedSettingsRevision: 0, projectionRevision: .initial)

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
        let target = SettingsCommandTarget(expectedSettingsRevision: 9, projectionRevision: .initial)

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
        let target = SettingsCommandTarget(expectedSettingsRevision: 0, projectionRevision: .initial)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .temporaryUnavailable)
        #expect(dependencies.config.revision == 0)
        #expect(dependencies.config.development.testArtists.isEmpty)
        #expect(result.refreshedSettings.saveErrorMessage != nil)
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
        let target = SettingsCommandTarget(expectedSettingsRevision: 0, projectionRevision: .initial)

        _ = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)
        let retry = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(retry.status == .accepted)
        #expect(dependencies.config.revision == 1)
        #expect(saved.configurations.count == 1)
    }
    @Test("a fingerprint-relevant change marks the current plan stale")
    func fingerprintChangeMarksPlanStale() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in }
        )
        // Settle runtime side effects (discogs availability) with one
        // accepted no-diff cycle before capturing the plan's baseline.
        _ = await SettingsCommands.apply(
            dependencies.config,
            target: SettingsCommandTarget(expectedSettingsRevision: 0, projectionRevision: .initial),
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
        edited.cleaning.remasterKeywords.append("Deluxe Probe Edition")
        let target = SettingsCommandTarget(expectedSettingsRevision: 1, projectionRevision: .initial)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(result.refreshedFixPlan?.stalenessReasons.contains(.configurationChanged) == true)
    }

    @Test("a presentation-only change leaves the plan projection untouched")
    func presentationChangeLeavesPlanUntouched() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in }
        )
        // Settle runtime side effects (discogs availability) with one
        // accepted no-diff cycle before capturing the plan's baseline.
        _ = await SettingsCommands.apply(
            dependencies.config,
            target: SettingsCommandTarget(expectedSettingsRevision: 0, projectionRevision: .initial),
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
        let target = SettingsCommandTarget(expectedSettingsRevision: 1, projectionRevision: .initial)

        let result = await SettingsCommands.apply(edited, target: target, dependencies: dependencies)

        #expect(result.status == .accepted)
        #expect(result.refreshedFixPlan?.stalenessReasons.isEmpty == true)
        #expect(result.refreshedFixPlan?.revision == baseline.revision)
    }

    @Test("a failed configuration load blocks scene-inactive saves")
    func loadFailureBlocksSceneSave() async {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { throw SaveProbeFailure() },
            configurationSaver: { saved.append($0) }
        )

        await dependencies.saveState()

        #expect(saved.configurations.isEmpty)
    }

    @Test("an explicit accepted command repairs a failed load")
    func explicitCommandRepairsFailedLoad() async {
        let saved = SavedConfigurations()
        let dependencies = AppDependencies(
            configurationLoader: { throw SaveProbeFailure() },
            configurationSaver: { saved.append($0) }
        )
        let target = SettingsCommandTarget(expectedSettingsRevision: 0, projectionRevision: .initial)

        let result = await SettingsCommands.apply(dependencies.config, target: target, dependencies: dependencies)
        await dependencies.saveState()

        #expect(result.status == .accepted)
        #expect(saved.configurations.count == 2)
    }
}

@MainActor
private final class SavedConfigurations {
    private(set) var configurations: [AppConfiguration] = []

    nonisolated init() {}

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
