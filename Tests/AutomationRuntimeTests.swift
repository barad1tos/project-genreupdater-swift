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
        #expect(!dependencies.isAutoSyncRunning)
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
        #expect(dependencies.isAutoSyncRunning)
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
        dependencies.isAutoSyncRunning = true

        await dependencies.submitScheduledObservation()

        #expect(dependencies.automationScheduleTask == nil)
        #expect(!dependencies.isAutoSyncRunning)
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
        dependencies.config.runtime.automationStrategy = .scheduled
        dependencies.lastScheduledTickAt = Date()

        await dependencies.completeLaunch()

        #expect(dependencies.automationScheduleTask != nil)
        #expect(dependencies.isAutoSyncRunning)

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
        #expect(dependencies.isAutoSyncRunning)

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
        #expect(dependencies.isAutoSyncRunning)

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

    @Test("a completed observation advances the durable mark and chrome cache")
    func completedObservationAdvancesDurableMark() async throws {
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
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: { _ in },
            onIncrementalWorkCompleted: { [weak dependencies] in
                await dependencies?.advanceIncrementalMark()
            }
        )))
        #expect(await tracker.getLastRunTimestamp() == nil)

        await dependencies.submitScheduledObservation()

        #expect(await tracker.getLastRunTimestamp() != nil)
        #expect(dependencies.lastIncrementalRunTimestamp != nil)
    }

    @Test("an empty observation leaves the durable mark untouched")
    func emptyObservationLeavesDurableMarkUntouched() async throws {
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
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            onIncrementalWorkCompleted: { [weak dependencies] in
                await dependencies?.advanceIncrementalMark()
            }
        )))

        await dependencies.submitScheduledObservation()

        #expect(await tracker.getLastRunTimestamp() == nil)
        #expect(dependencies.lastIncrementalRunTimestamp == nil)
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
