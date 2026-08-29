import Foundation
import Testing
@testable import Services

@Suite("Lifecycle relay")
struct LifecycleRelayTests {
    private func makeOrchestrator() -> RunOrchestrator {
        RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
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
        await waitUntil { await relay.latestSnapshot()?.isActive == false }

        let updates = await relay.subscribe()
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()

        // The replayed snapshot is the run's TERMINAL state, not a stale
        // active frame.
        #expect(first?.isActive == false)
    }

    @Test("an active snapshot of a detached orchestrator never replays")
    func phantomActiveSnapshotDoesNotReplay() async {
        // A run left ACTIVE on the old orchestrator can never deliver its
        // terminal boundary through the relay — replaying it would show a
        // phantom running state forever (the pitfall-50 class).
        let relay = LifecycleRelay()
        let never = AsyncStream<Void> { _ in
            // Never yields: the first orchestrator's run stays active.
        }
        let hangingOrchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in
                for await _ in never {
                    // Suspends forever.
                }
                return SyncResult()
            },
            persistRunRecord: { _ in
                // Persistence is irrelevant to relay pins.
            }
        ))
        await relay.attach(to: hangingOrchestrator)
        let hangingSubmission = Task {
            await hangingOrchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await waitUntil { await hangingOrchestrator.activeLifecycle() != nil }
        let hangingRunID = await hangingOrchestrator.activeLifecycle()?.runID

        let rebuilt = makeOrchestrator()
        await relay.attach(to: rebuilt)
        let updates = await relay.subscribe()
        let firstTask = Task {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        }
        await submitObservation(rebuilt)

        let first = await firstTask.value
        #expect(first != nil)
        #expect(first?.runID != hangingRunID)
        hangingSubmission.cancel()
    }

    @Test("a detached orchestrator's emissions never reach subscribers")
    func detachedOrchestratorEmissionsAreExcluded() async {
        let relay = LifecycleRelay()
        let first = makeOrchestrator()
        await relay.attach(to: first)
        let updates = await relay.subscribe()

        let second = makeOrchestrator()
        await relay.attach(to: second)
        // The cancelled forwarding subscription unregisters from the old
        // orchestrator; wait for it so the old submit below emits into a
        // subscriber-free void, never into the relay.
        await waitUntil { await first.lifecycleSubscriberCount() == 0 }

        await submitObservation(first)
        let collectTask = Task {
            var snapshots: [RunLifecycleSnapshot] = []
            for await lifecycle in updates {
                snapshots.append(lifecycle)
                if !lifecycle.isActive {
                    break
                }
            }
            return snapshots
        }
        await submitObservation(second)
        let secondRunID = await second.currentLifecycle()?.runID

        let snapshots = await collectTask.value
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { $0.runID == secondRunID })
    }

    @Test("a rewire does not resurrect the previous session's terminal")
    func reattachDoesNotResurrectOldTerminal() async {
        // A subscription made AFTER the rewire speaks only the new
        // upstream's truth: the old session's terminal was intentionally
        // cleared and must not replay as if it were current.
        let relay = LifecycleRelay()
        let first = makeOrchestrator()
        await relay.attach(to: first)
        await submitObservation(first)
        await waitUntil { await relay.latestSnapshot() != nil }
        let firstRunID = await first.currentLifecycle()?.runID

        let rebuilt = makeOrchestrator()
        await relay.attach(to: rebuilt)
        let updates = await relay.subscribe()
        let firstElementTask = Task {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        }
        await submitObservation(rebuilt)

        let element = await firstElementTask.value
        #expect(element != nil)
        #expect(element?.runID != firstRunID)
    }

    @Test("dropping a consumer removes its relay subscription")
    func droppedConsumerRemovesSubscription() async {
        let relay = LifecycleRelay()
        let updates = await relay.subscribe()
        let consumer = Task {
            for await _ in updates {
                // Consumes until cancelled.
            }
        }
        #expect(await relay.subscriberCount() == 1)

        consumer.cancel()
        await waitUntil { await relay.subscriberCount() == 0 }

        #expect(await relay.subscriberCount() == 0)
    }

    /// Deadline-bounded async poll (the OrchestratorTests precedent) so
    /// cancellation/registration effects settle without fixed sleeps.
    private func waitUntil(
        deadline: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while clock.now < end {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
