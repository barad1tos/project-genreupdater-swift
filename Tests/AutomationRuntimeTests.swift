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

        // Switching back to manual disarms the source.
        dependencies.config.runtime.automationStrategy = .manualOnly
        await dependencies.applyAutomationStrategy()
        #expect(dependencies.automationScheduleTask == nil)
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
