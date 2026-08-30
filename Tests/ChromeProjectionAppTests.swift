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

    @Test("window, status bar, and menus render one chrome truth")
    func oneChromeTruthAcrossSurfaces() async {
        // P16: the window subscribes to the store stream while the status
        // bar and CommandMenu read the observable mirror. The lifecycle
        // path — the real runtime writer — must leave both identical, or
        // the menus would disagree with the window mid-run.
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to this truth pin.
            }
        )
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let lifecycle = RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: "one-truth-pin"
            ),
            startedAt: startedAt,
            phase: .active(.syncingLibrary)
        )

        await dependencies.publishLifecycleBoundary(lifecycle)

        let stored = await dependencies.projectionStore.currentChrome()
        #expect(dependencies.chrome == stored)
        #expect(stored.revision != .initial)
        #expect(dependencies.chrome.syncStatus.isRunActive)
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
            automation: ChromeAutomationFacts(strategy: .manualOnly, isScheduleArmed: false, isIncrementalDue: nil),
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

    // D6: the automation due-fact derives from the cached tracker read;
    // the default interval is one minute (GeneralConfiguration).
    @Test("an elapsed incremental interval reads as due")
    func elapsedIncrementalIntervalReadsDue() async {
        let dependencies = makeChromeTestDependencies()
        dependencies.lastIncrementalRunTimestamp = Date(timeIntervalSinceNow: -3600)

        let input = await dependencies.makeChromeInput()

        #expect(input.automation.isIncrementalDue == true)
    }

    @Test("an unelapsed incremental interval reads as not due")
    func unelapsedIncrementalIntervalReadsNotDue() async {
        let dependencies = makeChromeTestDependencies()
        dependencies.lastIncrementalRunTimestamp = Date()

        let input = await dependencies.makeChromeInput()

        #expect(input.automation.isIncrementalDue == false)
    }

    @Test("a missing tracker value keeps the due-fact unknown")
    func missingTrackerValueKeepsDueFactUnknown() async {
        let dependencies = makeChromeTestDependencies()

        let input = await dependencies.makeChromeInput()

        #expect(input.automation.isIncrementalDue == nil)
    }

    @Test("physical catalog count stays separate from the effective processing scope")
    func physicalCatalogAndProcessingScopeStaySeparate() async {
        let dependencies = makeChromeTestDependencies()
        dependencies.catalogSnapshot = CatalogSnapshot(tracks: [
            makeChromeCatalogTrack(id: "catalog-1"),
            makeChromeCatalogTrack(id: "catalog-2"),
            makeChromeCatalogTrack(id: "catalog-3"),
        ])
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        dependencies.currentLifecycleSnapshot = RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Clutch"],
                knownTrackCount: 1,
                createdAt: startedAt,
                reason: "chrome-catalog-scope-pin"
            ),
            startedAt: startedAt,
            phase: .active(.syncingLibrary)
        )

        let input = await dependencies.makeChromeInput()

        #expect(input.library.physicalTrackCount == 3)
        #expect(input.library.scope?.knownTrackCount == 1)
        #expect(input.library.scope?.source == .testArtists)
    }

    @Test("the interval is minutes, not seconds")
    func intervalIsMinutesNotSeconds() async {
        let dependencies = makeChromeTestDependencies()
        dependencies.config.runtime.incrementalIntervalMinutes = 120
        dependencies.lastIncrementalRunTimestamp = Date(timeIntervalSinceNow: -3600)

        let input = await dependencies.makeChromeInput()

        // One hour into a two-hour window: due only if the unit
        // conversion regresses (120 s would already have elapsed).
        #expect(input.automation.isIncrementalDue == false)
    }

    @Test("a zero interval clamps to the scheduler's one-minute floor")
    func zeroIntervalClampsToSchedulerFloor() async {
        let dependencies = makeChromeTestDependencies()
        dependencies.config.runtime.incrementalIntervalMinutes = 0
        dependencies.lastIncrementalRunTimestamp = Date(timeIntervalSinceNow: -30)

        let input = await dependencies.makeChromeInput()

        // Thirty seconds after the last run: an unclamped zero interval
        // would read due while the scheduler still waits at its floor.
        #expect(input.automation.isIncrementalDue == false)
    }

    private func makeChromeTestDependencies() -> AppDependencies {
        AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to these due-fact pins.
            }
        )
    }
}

private struct ChromeProbeFailure: Error {}

private func makeChromeCatalogTrack(id: String) -> CatalogTrack {
    guard let catalogID = CatalogTrackID(displayValue: id) else {
        preconditionFailure("Chrome fixture catalog IDs must be non-empty")
    }
    return CatalogTrack(
        id: catalogID,
        title: "Track",
        artist: "Artist",
        album: "Album",
        albumArtist: nil,
        genres: [],
        dates: CatalogDates(releaseYear: nil, dateAdded: nil)
    )
}
