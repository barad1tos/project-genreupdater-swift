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
        let baselineFingerprint = dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        ).fingerprint
        let baselineRevision = dependencies.config.revision
        let baselineProjection = await dependencies.projectionStore.currentSettings()

        // Measure WHILE casual is in effect, and force a republish so a
        // level-derived projection field could not slip through unnoticed.
        defaults.set(ExperienceLevel.casual.rawValue, forKey: AppStorageKey.experienceLevel)

        let casualFingerprint = dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        ).fingerprint
        let casualProjection = await dependencies.publishSettingsProjection()

        #expect(casualFingerprint == baselineFingerprint)
        #expect(dependencies.config.revision == baselineRevision)
        // SettingsProjection equality includes canonical configuration
        // bytes; the store's dedup keeps the revision when nothing changed.
        #expect(casualProjection == baselineProjection)
    }

    @Test("persisted raw values stay stable")
    func rawValuesStayStable() {
        #expect(ExperienceLevel(rawValue: "casual") == .casual)
        #expect(ExperienceLevel(rawValue: "advanced") == .advanced)
        #expect(ExperienceLevel.advanced.rawValue == "advanced")
    }
}
