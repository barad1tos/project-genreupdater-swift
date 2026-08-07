import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Experience level")
@MainActor
struct ExperienceLevelTests {
    @Test("switching the level never touches configuration, fingerprint, or projection")
    func experienceLevelIsDisplayOnly() async {
        let defaults = UserDefaults.standard
        // Clear residue from an interrupted earlier run before flipping.
        defaults.removeObject(forKey: AppStorageKey.experienceLevel)
        defer { defaults.removeObject(forKey: AppStorageKey.experienceLevel) }
        let dependencies = AppDependencies(
            configurationLoader: {
                var configuration = AppConfiguration()
                configuration.development.testArtists = ["Display Only Probe"]
                return configuration
            },
            configurationSaver: { _ in
                // The level must never trigger persistence.
            }
        )
        await dependencies.publishSettingsProjection()
        let baselineFingerprint = dependencies.capturePreviewConfig(
            at: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        ).fingerprint
        let baselineRevision = dependencies.config.revision
        let baselineProjection = await dependencies.projectionStore.currentSettings()

        defaults.set(ExperienceLevel.casual.rawValue, forKey: AppStorageKey.experienceLevel)
        defaults.set(ExperienceLevel.advanced.rawValue, forKey: AppStorageKey.experienceLevel)

        let flippedFingerprint = dependencies.capturePreviewConfig(
            at: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        ).fingerprint
        #expect(flippedFingerprint == baselineFingerprint)
        #expect(dependencies.config.revision == baselineRevision)
        let flippedProjection = await dependencies.projectionStore.currentSettings()
        #expect(flippedProjection == baselineProjection)
    }

    @Test("persisted raw values stay stable")
    func rawValuesStayStable() {
        #expect(ExperienceLevel(rawValue: "casual") == .casual)
        #expect(ExperienceLevel(rawValue: "advanced") == .advanced)
        #expect(ExperienceLevel.advanced.rawValue == "advanced")
    }
}
