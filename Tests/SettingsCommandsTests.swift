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
