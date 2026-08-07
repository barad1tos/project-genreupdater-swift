import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Chrome projection app wiring")
@MainActor
struct ChromeProjectionAppTests {
    @Test("initialization bootstraps chrome with probed settings truth")
    func initializeBootstrapsChrome() async {
        let dependencies = AppDependencies(
            configurationLoader: {
                var configuration = AppConfiguration()
                configuration.runtime.dryRun = false
                return configuration
            },
            configurationSaver: { _ in
                // Persistence is irrelevant to this bootstrap pin.
            }
        )

        await dependencies.initialize()
        let current = await dependencies.projectionStore.currentChrome()

        // "Auto-fix" differs from the empty sentinel's "Preview", proving
        // the bootstrap publish landed with the loaded configuration.
        #expect(current.processingModeLabel == "Auto-fix")
    }

    @Test("a failed load surfaces as a chrome configuration issue")
    func failedLoadSurfacesInChrome() async {
        let dependencies = AppDependencies(
            configurationLoader: { throw ChromeProbeFailure() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this pin.
            }
        )

        await dependencies.initialize()
        let current = await dependencies.projectionStore.currentChrome()

        #expect(current.operationalIssues.contains { $0.category == .configurationRequired })
    }

    @Test("an accepted settings command republishes chrome truth")
    func settingsAcceptRepublishesChrome() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence side effects are irrelevant to this pin.
            }
        )
        _ = await dependencies.refreshChromeProjection()
        let baseline = await dependencies.projectionStore.currentChrome()
        #expect(baseline.processingModeLabel == "Auto-fix")
        var edited = dependencies.config
        edited.runtime.dryRun = true

        let result = await SettingsCommands.apply(
            edited,
            target: SettingsCommandTarget(expectedSettingsRevision: 0),
            dependencies: dependencies
        )
        let updated = await dependencies.projectionStore.currentChrome()

        #expect(result.status == .accepted)
        #expect(updated.processingModeLabel == "Preview")
        #expect(updated.revision != baseline.revision)
    }

    @Test("a content-identical chrome refresh keeps the revision")
    func identicalRefreshKeepsRevision() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this dedup pin.
            }
        )

        let first = await dependencies.refreshChromeProjection()
        let second = await dependencies.refreshChromeProjection()

        #expect(second.revision == first.revision)
    }
}

private struct ChromeProbeFailure: Error {}
