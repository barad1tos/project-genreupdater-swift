import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

/// Slice 13 (ADR 0003): the schedule strategy submits REAL runs through
/// the orchestrator — records and arbitration come from the canonical
/// pipeline, and arming honors the persisted strategy plus the Pro gate.
@Suite("Automation runtime")
@MainActor
struct AutomationRuntimeTests {
    @Test("a scheduled tick submits a background observation with a record")
    func scheduledTickSubmitsBackgroundObservation() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.submitScheduledObservation()

        let stored = await records.records
        #expect(stored.first?.trigger == .backgroundSync)
        #expect(stored.first?.intent == .observeLibrary)
        #expect(stored.last?.finishedAt != nil)
    }

    @Test("a scheduled tick during an active manual run is absorbed")
    func scheduledTickDuringActiveManualRunIsAbsorbed() async {
        let gate = AutomationSyncGate()
        let records = AutomationRecordCollector()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await gate.sync() },
            persistRunRecord: { await records.append($0) }
        ))
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        await dependencies.installTestOrchestrator(orchestrator)

        await gate.arm()
        let manual = Task {
            await orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await gate.waitUntilEntered()

        // ADR 0003 coalescing: the active manual observation COVERS the
        // lower-ranked background tick — no displacement, no duplicate.
        await dependencies.submitScheduledObservation()
        let activeAfterTick = await orchestrator.activeLifecycle()
        #expect(activeAfterTick?.trigger == .manualCheck)

        await gate.release()
        _ = await manual.value

        let terminalTriggers = await records.records.filter { $0.finishedAt != nil }.map(\.trigger)
        #expect(terminalTriggers == [.manualCheck])
    }

    @Test("the manual strategy arms nothing")
    func manualStrategyArmsNothing() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .manualOnly

        await dependencies.applyAutomationStrategy()

        #expect(dependencies.automationScheduleTask == nil)
    }

    @Test("the scheduled strategy arms the schedule source under Pro")
    func scheduledStrategyArmsUnderPro() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .scheduled

        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationScheduleTask != nil)

        // Switching back to manual disarms the source AND publishes it.
        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationScheduleTask == nil)
        #expect(!dependencies.isAutomationArmed)
    }

    @Test("the strategy command persists the choice and re-arms the runtime")
    func strategyCommandPersistsAndRearms() async {
        let savedStrategies = SavedStrategiesBox()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { configuration in
                savedStrategies.values.append(configuration.runtime.automationStrategy)
            }
        )
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))

        let status = mutateConfiguration(dependencies) { configuration in
            configuration.runtime.automationStrategy = .scheduled
        }
        #expect(status == .accepted)
        #expect(savedStrategies.values.last == .scheduled)

        // The command's runtime apply re-arms the schedule source.
        await dependencies.runtimeApplyQueue?.value
        #expect(dependencies.automationScheduleTask != nil)
        #expect(dependencies.isAutomationArmed)
    }

    @Test("a free tier never arms an automation source")
    func freeTierNeverArms() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .free))
        dependencies.config.runtime.automationStrategy = .hybrid

        await dependencies.applyAutomationStrategy()

        #expect(dependencies.automationScheduleTask == nil)
    }

    @Test("an armed loop with no anchor fires its first tick immediately")
    func armedLoopFiresFirstTickImmediately() async throws {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .scheduled
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        // No tracker and no in-memory tick anchor → fail open, tick now.
        await dependencies.applyAutomationStrategy()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var landed = false
        while clock.now < deadline {
            if await records.records.first?.trigger == .backgroundSync {
                landed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(landed, "the armed loop must actually submit its first tick")

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("an identical re-arm keeps the live loop instead of resetting it")
    func identicalRearmKeepsLiveLoop() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .scheduled
        dependencies.lastScheduledTickAt = Date()

        await dependencies.applyAutomationStrategy()
        let firstTask = dependencies.automationScheduleTask
        #expect(firstTask != nil)

        // A settings apply with unchanged strategy+interval must NOT
        // cancel and re-create the loop (each reset re-anchors the
        // tick); a re-arm would cancel the first task.
        await dependencies.applyAutomationStrategy()
        #expect(firstTask?.isCancelled == false)
        #expect(dependencies.automationScheduleTask != nil)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("schedule delay math is pure Python parity")
    func scheduleDelayMathIsPythonParity() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(AppDependencies.scheduleDelay(anchor: nil, now: now, interval: 60) == 0)
        #expect(AppDependencies.scheduleDelay(anchor: now.addingTimeInterval(-90), now: now, interval: 60) == 0)
        #expect(AppDependencies.scheduleDelay(anchor: now.addingTimeInterval(-20), now: now, interval: 60) == 40)
    }

    @Test("a lapsed gate disarms the loop at the next tick")
    func lapsedGateDisarmsAtTick() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .free))
        dependencies.automationScheduleTask = Task {}
        dependencies.isAutomationArmed = true

        await dependencies.submitScheduledObservation()

        #expect(dependencies.automationScheduleTask == nil)
        #expect(!dependencies.isAutomationArmed)
    }

    @Test("hybrid arms the schedule source; libraryChange arms nothing yet")
    func hybridArmsAndLibraryChangeDoesNot() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.lastScheduledTickAt = Date()

        dependencies.config.runtime.automationStrategy = .hybrid
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationScheduleTask != nil)

        dependencies.config.runtime.automationStrategy = .libraryChange
        await dependencies.applyAutomationStrategy()
        // The watch source is a later slice: libraryChange must not
        // silently inherit periodic checks.
        #expect(dependencies.automationScheduleTask == nil)
    }

    @Test("launch completion arms the persisted strategy")
    func launchCompletionArmsPersistedStrategy() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.installTestAgentRegistrar(StubAgentRegistrar())
        dependencies.config.runtime.automationStrategy = .scheduled
        dependencies.lastScheduledTickAt = Date()

        await dependencies.completeLaunch()

        #expect(dependencies.automationScheduleTask != nil)
        #expect(dependencies.isAutomationArmed)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("a watch event submits a file-system observation with a record")
    func watchEventSubmitsFileSystemObservation() async throws {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .libraryChange
        let source = StubLibraryChangeSource(isAvailable: true)
        dependencies.libraryChangeSource = source
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationWatchTask != nil)
        #expect(dependencies.automationScheduleTask == nil)

        source.emit()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var landed = false
        while clock.now < deadline {
            if await records.records.first?.trigger == .fileSystemEvent {
                landed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(landed, "a watch event must submit a real observation")

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("watch events inside the throttle window coalesce")
    func watchEventsInsideThrottleWindowCoalesce() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.submitWatchObservation()
        await dependencies.submitWatchObservation()

        // Python launchd ThrottleInterval parity: the second event inside
        // 300 s coalesces into the first tick.
        let terminals = await records.records.filter { $0.finishedAt != nil }
        #expect(terminals.count == 1)
        #expect(terminals.first?.trigger == .fileSystemEvent)
    }

    @Test("an unavailable watch source degrades hybrid to schedule only")
    func unavailableWatchSourceDegradesHybrid() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .hybrid
        dependencies.libraryChangeSource = StubLibraryChangeSource(isAvailable: false)
        dependencies.lastScheduledTickAt = Date()

        await dependencies.applyAutomationStrategy()

        #expect(dependencies.automationScheduleTask != nil)
        #expect(dependencies.automationWatchTask == nil)
        #expect(dependencies.isAutomationArmed)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("hybrid with an available source arms both sources")
    func hybridArmsBothSources() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .hybrid
        dependencies.libraryChangeSource = StubLibraryChangeSource(isAvailable: true)
        dependencies.lastScheduledTickAt = Date()

        await dependencies.applyAutomationStrategy()

        #expect(dependencies.automationScheduleTask != nil)
        #expect(dependencies.automationWatchTask != nil)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationWatchTask == nil)
    }

    @Test("a lapsed gate disarms the watch source at the next event")
    func lapsedGateDisarmsWatchAtEvent() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .free))
        dependencies.automationWatchTask = Task {}
        dependencies.armedWatchPath = "probe"

        await dependencies.submitWatchObservation()

        #expect(dependencies.automationWatchTask == nil)
        #expect(dependencies.armedWatchPath == nil)
    }

    @Test("the real file watcher emits on writes and probes availability")
    func realFileWatcherEmitsOnWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatcherProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.probe")
        try Data("initial".utf8).write(to: file)

        let watcher = MusicLibraryFileWatcher(libraryPath: file.path)
        #expect(watcher.isAvailable)

        let missing = MusicLibraryFileWatcher(libraryPath: directory.appendingPathComponent("absent").path)
        #expect(!missing.isAvailable)

        let stream = watcher.events()
        let firstEvent = Task { () -> Bool in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        try await Task.sleep(for: .milliseconds(100))
        try Data("mutated".utf8).write(to: file)

        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
            firstEvent.cancel()
        }
        let emitted = await firstEvent.value
        timeout.cancel()
        #expect(emitted, "a write to the watched file must emit an event")
    }

    @Test("an event after the throttle window submits again")
    func eventAfterThrottleWindowSubmitsAgain() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.submitWatchObservation()
        dependencies.lastWatchTickAt = Date().addingTimeInterval(-(AppDependencies.watchThrottleInterval + 1))
        await dependencies.submitWatchObservation()

        let terminals = await records.records.filter { $0.finishedAt != nil }
        #expect(terminals.count == 2)
    }

    @Test("a throttled event defers to one trailing tick, never drops")
    func throttledEventDefersToTrailingTick() async throws {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        // Nearly-expired window: the in-window event must arm a trailing
        // tick that fires when the remainder elapses (launchd defer
        // parity), not vanish.
        dependencies.lastWatchTickAt = Date().addingTimeInterval(-(AppDependencies.watchThrottleInterval - 0.2))
        await dependencies.submitWatchObservation()
        #expect(dependencies.automationWatchTrailingTask != nil)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var landed = false
        while clock.now < deadline {
            let terminals = await records.records.filter { $0.finishedAt != nil }
            if terminals.count == 1 {
                landed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(landed, "the trailing tick must service the throttled event")
        #expect(dependencies.automationWatchTrailingTask == nil)
    }

    @Test("a path change rebuilds the self-built watcher")
    func pathChangeRebuildsSelfBuiltWatcher() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatcherRebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.probe")
        let second = directory.appendingPathComponent("second.probe")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .libraryChange
        dependencies.config.paths.musicLibraryPath = first.path
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.libraryChangeSourceBuiltPath == first.path)

        // The configured path moves: the next apply must rebuild the
        // watcher for the new path, not keep watching the old file.
        dependencies.config.paths.musicLibraryPath = second.path
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.libraryChangeSourceBuiltPath == second.path)
        #expect(dependencies.armedWatchPath == second.path)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("disarming terminates the stub stream")
    func disarmingTerminatesStubStream() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .libraryChange
        let source = StubLibraryChangeSource(isAvailable: true)
        dependencies.libraryChangeSource = source
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationWatchTask != nil)
        // Pure libraryChange arming publishes the armed fact too.
        #expect(dependencies.isAutomationArmed)

        // Prove the consumer subscribed before disarming: an emitted
        // event must land as a record first.
        source.emit()
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(3))
        var subscribed = false
        while clock.now < deadline {
            if await !records.records.isEmpty {
                subscribed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(subscribed)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()

        deadline = clock.now.advanced(by: .seconds(2))
        var terminated = false
        while clock.now < deadline {
            if source.isTerminated {
                terminated = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminated, "disarm must tear the stream down, not leak the source")
    }

    /// The tracker file is the PROCESSING watermark: the manual incremental
    /// batch anchors its newTracks window on it (UpdateTrackScopeResolver).
    /// An observation only looks — advancing the mark here would burn that
    /// window for tracks nobody processed (PR #160 review, Codex P1 +
    /// panel convergent). Python parity: the mark moves only at the end of
    /// a processing run.
    @Test("a completed observation leaves the processing watermark untouched")
    func completedObservationLeavesWatermarkUntouched() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let tracker = IncrementalRunTracker(
            logsBaseDirectory: tempDirectory.path,
            lastIncrementalRunFile: "last_incremental_run.log"
        )
        dependencies.installTestIncrementalRunTracker(tracker)
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.submitScheduledObservation()

        // Positive control: without proof the observation COMPLETED, the
        // nil asserts below would pass vacuously on a broken fixture.
        let terminal = await records.records.last
        #expect(terminal?.intent == .observeLibrary)
        #expect(terminal?.finishedAt != nil)
        #expect(await tracker.getLastRunTimestamp() == nil)
        #expect(dependencies.lastIncrementalRunTimestamp == nil)
    }

    @Test("an agent wake URL lands a file-system observation")
    func agentWakeSubmitsFileSystemObservation() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .libraryChange
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.handleAutomationWake(url: automationWakeURL())

        let stored = await records.records
        #expect(stored.first?.trigger == .fileSystemEvent)
        #expect(stored.first?.intent == .observeLibrary)
    }

    @Test("a wake under the manual strategy submits nothing")
    func agentWakeUnderManualStrategySubmitsNothing() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .manualOnly
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.handleAutomationWake(url: automationWakeURL())

        #expect(await records.records.isEmpty)
    }

    @Test("a wake on the free tier submits nothing")
    func agentWakeOnFreeTierSubmitsNothing() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .free))
        dependencies.config.runtime.automationStrategy = .hybrid
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.handleAutomationWake(url: automationWakeURL())

        #expect(await records.records.isEmpty)
    }

    @Test("a junk URL submits nothing")
    func junkURLSubmitsNothing() async throws {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .hybrid
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        let junkHost = try #require(URL(string: "genreupdater://something/else"))
        await dependencies.handleAutomationWake(url: junkHost)
        let junkPath = try #require(URL(string: "genreupdater://automation/not-a-thing"))
        await dependencies.handleAutomationWake(url: junkPath)

        #expect(await records.records.isEmpty)
    }

    /// The convergent HIGH of the PR-161 wave: a cold-launch wake races
    /// initialize() and used to be silently dropped — the very change the
    /// agent woke the app for. The wake now parks until completeLaunch
    /// drains it through the runtime.
    @Test("a wake before the runtime exists parks and drains at launch")
    func coldLaunchWakeParksAndDrains() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.config.runtime.automationStrategy = .libraryChange

        // No gate, no orchestrator yet — the pre-fix path dropped here.
        await dependencies.handleAutomationWake(url: automationWakeURL())
        #expect(dependencies.pendingAutomationWakeURL != nil)

        let records = AutomationRecordCollector()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.installTestAgentRegistrar(StubAgentRegistrar())
        dependencies.libraryChangeSource = StubLibraryChangeSource(isAvailable: false)
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))

        await dependencies.completeLaunch()

        let stored = await records.records
        #expect(stored.first?.trigger == .fileSystemEvent)
        #expect(dependencies.pendingAutomationWakeURL == nil)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    /// Codex P2: with the in-process watcher armed, an agent nudge is the
    /// SAME change seen twice — deferring it would re-observe ~5 minutes
    /// later for nothing. Live wakes yield to the armed source.
    @Test("a live wake with an armed in-process source is ignored")
    func liveWakeWithArmedSourceIsIgnored() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        dependencies.config.runtime.automationStrategy = .libraryChange
        dependencies.libraryChangeSource = StubLibraryChangeSource(isAvailable: true)
        let records = AutomationRecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) }
        )))
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationWatchTask != nil)

        await dependencies.handleAutomationWake(url: automationWakeURL())

        #expect(await records.records.isEmpty)

        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
    }

    @Test("the watcher toggle registers and unregisters through the registrar")
    func watcherToggleDrivesRegistrar() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let registrar = StubAgentRegistrar()
        dependencies.installTestAgentRegistrar(registrar)

        let enableFailure = await dependencies.setBackgroundWatcherEnabled(true)
        #expect(enableFailure == nil)
        #expect(registrar.registerCalls == 1)

        let disableFailure = await dependencies.setBackgroundWatcherEnabled(false)
        #expect(disableFailure == nil)
        #expect(registrar.unregisterCalls == 1)
    }

    @Test("a lapsed tier cannot enable but can always disable")
    func lapsedTierCannotEnableButCanDisable() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .free))
        let registrar = StubAgentRegistrar()
        registrar.isRegistered = true
        dependencies.installTestAgentRegistrar(registrar)

        let enableFailure = await dependencies.setBackgroundWatcherEnabled(true)
        #expect(enableFailure?.isEmpty == false)
        #expect(registrar.registerCalls == 0)

        // The escape hatch: a registered agent must remain removable.
        let disableFailure = await dependencies.setBackgroundWatcherEnabled(false)
        #expect(disableFailure == nil)
        #expect(registrar.unregisterCalls == 1)
    }

    @Test("a registrar failure surfaces as a user-facing message")
    func registrarFailureSurfacesMessage() async {
        let dependencies = makeAutomationTestDependencies()
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let registrar = StubAgentRegistrar()
        registrar.failure = AgentRegistrationFailure.denied
        dependencies.installTestAgentRegistrar(registrar)

        let failure = await dependencies.setBackgroundWatcherEnabled(true)
        #expect(failure?.isEmpty == false)
    }

    @Test("a missing registrar reports unavailability instead of crashing")
    func missingRegistrarReportsUnavailability() async {
        let dependencies = makeAutomationTestDependencies()

        let failure = await dependencies.setBackgroundWatcherEnabled(true)
        #expect(failure?.isEmpty == false)
    }

    private func automationWakeURL() -> URL {
        guard let url = URL(string: "genreupdater://automation/library-change") else {
            fatalError("the wake URL constant is unparseable")
        }
        return url
    }

    private func makeAutomationTestDependencies() -> AppDependencies {
        AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to these runtime pins.
            }
        )
    }
}

/// The saver closure runs synchronously on MainActor with the command.
@MainActor
private final class SavedStrategiesBox {
    var values: [AutomationStrategy] = []
}

/// Records registration calls; a set failure throws instead.
@MainActor
final class StubAgentRegistrar: AgentRegistrar {
    var isRegistered = false
    var needsApproval = false
    var failure: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() throws {
        if let failure {
            throw failure
        }
        registerCalls += 1
        isRegistered = true
    }

    func unregister() async throws {
        if let failure {
            throw failure
        }
        unregisterCalls += 1
        isRegistered = false
    }

    func openApprovalSettings() {
        // Settings deep links are outside pin scope.
    }
}

enum AgentRegistrationFailure: Error {
    case denied
}

/// A hand-driven source: tests emit events and control availability.
/// The stream is created eagerly so an emit before the consumer
/// subscribes is buffered, not lost.
final class StubLibraryChangeSource: LibraryChangeSource, @unchecked Sendable {
    let isAvailable: Bool
    private(set) var isTerminated = false
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.onTermination = { [self] _ in
            isTerminated = true
        }
    }

    func events() -> AsyncStream<Void> {
        stream
    }

    func emit() {
        continuation.yield()
    }
}

private actor AutomationRecordCollector {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

private actor AutomationSyncGate {
    private var isArmed = false
    private var isReleased = false
    private var isEntered = false
    private var enterContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
    }

    func sync() async -> SyncResult {
        guard isArmed, !isReleased else { return SyncResult() }
        isEntered = true
        for continuation in enterContinuations {
            continuation.resume()
        }
        enterContinuations = []
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        return SyncResult()
    }

    func waitUntilEntered() async {
        if isEntered {
            return
        }
        await withCheckedContinuation { continuation in
            enterContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }
}
