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
