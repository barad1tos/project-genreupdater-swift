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
        #expect(current.safety.processingModeLabel == "Auto-fix")
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
        #expect(baseline.safety.processingModeLabel == "Auto-fix")
        var edited = dependencies.config
        edited.runtime.dryRun = true

        let result = await SettingsCommands.apply(
            edited,
            target: SettingsCommandTarget(expectedSettingsRevision: 0),
            dependencies: dependencies
        )
        let updated = await dependencies.projectionStore.currentChrome()

        #expect(result.status == .accepted)
        #expect(updated.safety.processingModeLabel == "Preview")
        #expect(updated.revision != baseline.revision)
    }

    @Test("the observable chrome mirror follows the projection")
    func chromeMirrorFollowsProjection() async {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this mirror pin.
            }
        )
        #expect(dependencies.chrome.commands.isEmpty)

        let published = await dependencies.refreshChromeProjection()

        #expect(dependencies.chrome == published)
        #expect(dependencies.chrome.commands.contains { $0.commandKind == .runManually })
    }

    @Test("the status item symbol follows severity")
    func statusItemSymbolFollowsSeverity() {
        #expect(StatusBarSymbol.name(for: .nominal) == "music.note")
        #expect(StatusBarSymbol.name(for: .attention) == "exclamationmark.triangle")
        #expect(StatusBarSymbol.name(for: .blocked) == "exclamationmark.octagon.fill")
    }

    @Test("the design chrome mirror maps facts without derivation")
    func designChromeMirrorMapsFacts() {
        let design = ActivitySnapshotAdapter.makeChrome(from: .empty())

        #expect(design.syncSeverity == .nominal)
        #expect(design.syncStatusText == "Idle")
        #expect(design.processingModeLabel == "Preview")
        #expect(design.isAutoFixEnabled == false)
        #expect(design.automationLabel == "Manual trigger")
        #expect(design.narrowedScopeLabel == nil)
    }

    @Test("the design chrome mirror maps severity and scope narrowing")
    func designChromeMirrorMapsSeverityAndScope() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Clutch"],
            knownTrackCount: 10,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "mirror-pin"
        )
        let projection = ChromeBuilder.makeProjection(input: ChromeInput(
            run: ChromeRunFacts(lifecycle: nil, isRunServiceAvailable: true),
            recovery: ChromeRecoveryFacts(hasUnresolvedWriteRecovery: true, recoveryRunID: nil),
            settings: ChromeSettingsFacts(isPreviewMode: false, saveErrorMessage: nil, hasLoadFailed: false),
            automation: ChromeAutomationFacts(isAutoSyncRunning: false, isIncrementalDue: nil),
            library: ChromeLibraryFacts(physicalTrackCount: nil, scope: scope),
            permissions: .unprobed
        ))

        let design = ActivitySnapshotAdapter.makeChrome(from: projection)

        #expect(design.syncSeverity == .blocked)
        #expect(design.isAutoFixEnabled == true)
        #expect(design.narrowedScopeLabel == "Last run: Test artists (1)")
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
