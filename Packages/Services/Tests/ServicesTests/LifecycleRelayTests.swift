import Foundation
import Testing
@testable import Services

@Suite("Lifecycle relay")
struct LifecycleRelayTests {
    private func makeOrchestrator() -> RunOrchestrator {
        RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in
                // Persistence is irrelevant to relay pins.
            }
        ))
    }

    private func submitObservation(_ orchestrator: RunOrchestrator) async {
        _ = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
    }

    @Test("a subscription made before any orchestrator delivers after attach")
    func subscribeBeforeAttachDeliversAfterAttach() async {
        let relay = LifecycleRelay()
        let updates = await relay.subscribe()
        let received = Task {
            var snapshots: [RunLifecycleSnapshot] = []
            for await lifecycle in updates {
                snapshots.append(lifecycle)
                if !lifecycle.isActive {
                    break
                }
            }
            return snapshots
        }

        let orchestrator = makeOrchestrator()
        await relay.attach(to: orchestrator)
        await submitObservation(orchestrator)

        let snapshots = await received.value
        #expect(!snapshots.isEmpty)
        #expect(snapshots.contains { !$0.isActive })
    }

    @Test("two subscribers both see one boundary")
    func twoSubscribersSeeOneBoundary() async {
        let relay = LifecycleRelay()
        let first = await relay.subscribe()
        let second = await relay.subscribe()
        let firstTask = Task { await first.first { !$0.isActive } }
        let secondTask = Task { await second.first { !$0.isActive } }

        let orchestrator = makeOrchestrator()
        await relay.attach(to: orchestrator)
        await submitObservation(orchestrator)

        let firstTerminal = await firstTask.value
        let secondTerminal = await secondTask.value
        #expect(firstTerminal != nil)
        #expect(firstTerminal?.runID == secondTerminal?.runID)
    }

    @Test("a subscription survives an orchestrator rebuild")
    func reattachContinuesSubscription() async {
        let relay = LifecycleRelay()
        let firstOrchestrator = makeOrchestrator()
        await relay.attach(to: firstOrchestrator)
        await submitObservation(firstOrchestrator)

        let updates = await relay.subscribe()
        let secondOrchestrator = makeOrchestrator()
        await relay.attach(to: secondOrchestrator)
        let terminalTask = Task {
            var terminals: [RunLifecycleSnapshot] = []
            for await lifecycle in updates where !lifecycle.isActive {
                terminals.append(lifecycle)
                if terminals.count == 2 {
                    break
                }
            }
            return terminals
        }
        await submitObservation(secondOrchestrator)

        // The SAME subscription sees the first orchestrator's cached
        // terminal (latest at subscribe) AND the rebuilt one's boundary.
        let terminals = await terminalTask.value
        #expect(terminals.count == 2)
        #expect(terminals[0].runID != terminals[1].runID)
    }

    @Test("a late subscriber resynchronizes from the latest snapshot")
    func lateSubscriberGetsLatest() async {
        let relay = LifecycleRelay()
        let orchestrator = makeOrchestrator()
        await relay.attach(to: orchestrator)
        await submitObservation(orchestrator)
        // Let the forwarding task drain the boundary into the relay.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        let updates = await relay.subscribe()
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()

        #expect(first != nil)
    }
}
