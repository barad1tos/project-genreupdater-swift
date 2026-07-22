import Foundation
import Testing
@testable import Services

@Suite("Lifecycle buffering")
struct LifecycleBufferTests {
    @Test("terminal overflow retains the newest ordered suffix")
    func retainsNewestTerminals() async {
        let buffer = LifecycleUpdateBuffer(limit: 3)
        let runs = (0 ..< 4).map { _ in RunID() }
        for runID in runs {
            buffer.push(terminal(runID))
        }

        let retained = await [buffer.next(), buffer.next(), buffer.next()]

        #expect(retained.compactMap { $0?.runID } == Array(runs.suffix(3)))
    }

    @Test("overflow drops superseded active progress before terminals")
    func dropsActiveProgress() async {
        let buffer = LifecycleUpdateBuffer(limit: 3)
        let first = terminal(RunID())
        let active = active(RunID())
        let second = terminal(RunID())
        let newest = terminal(RunID())
        buffer.push(first)
        buffer.push(active)
        buffer.push(second)
        buffer.push(newest)

        let retained = await [buffer.next(), buffer.next(), buffer.next()]

        #expect(retained.compactMap { $0?.runID } == [first.runID, second.runID, newest.runID])
    }

    @Test("slow subscriber keeps a terminal snapshot before queued checkpoint progress")
    func preservesTerminalOrder() async throws {
        let gate = CheckpointRunGate()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: { _ in
                // Record persistence is outside this in-memory buffer test.
            },
            write: .init(writeFixPlan: { _, checkpoint in
                for _ in 0 ..< RunOrchestrator.lifecycleBufferLimit * 2 {
                    try await checkpoint(.beforeAttempt([itemID]))
                }
                try await checkpoint(.afterAttempt([itemID]))
                try await checkpoint(.afterVerification([itemID: .written]))
                return BatchUpdateResult(entries: [writeEntry()], failedTrackIDs: [], errorDescriptions: [])
            })
        ))
        let updates = await orchestrator.lifecycleUpdates()
        let iterator = SnapshotIterator(updates: updates)
        let first = Task {
            await orchestrator.submit(.observation(
                trigger: .backgroundSync,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        guard case .queued = await orchestrator.submit(.manualWrite(input: input)) else {
            Issue.record("Expected write to queue")
            return
        }
        await gate.release()
        let firstResult = await first.value
        let secondTerminal = try await waitForQueuedTerminal(orchestrator, after: firstResult.lifecycle.runID)

        var snapshots: [RunLifecycleSnapshot] = []
        while let snapshot = try await nextSnapshot(from: iterator) {
            snapshots.append(snapshot)
            if snapshot.runID == secondTerminal.runID, !snapshot.isActive {
                break
            }
        }

        let firstTerminalIndex = try #require(snapshots.firstIndex {
            $0.runID == firstResult.lifecycle.runID && !$0.isActive
        })
        let secondRunIndex = try #require(snapshots.firstIndex {
            $0.runID == secondTerminal.runID
        })
        #expect(firstTerminalIndex < secondRunIndex)
    }

    @Test("snapshot waits stop at their deadline")
    func snapshotWaitTimesOut() async {
        let updates = LifecycleUpdates(buffer: LifecycleUpdateBuffer(limit: 1))
        let iterator = SnapshotIterator(updates: updates)

        await #expect(throws: BufferTestError.snapshotTimedOut) {
            try await nextSnapshot(from: iterator, timeout: .milliseconds(20))
        }
    }

    private func terminal(_ runID: RunID) -> RunLifecycleSnapshot {
        lifecycle(
            runID,
            phase: .finished(
                .completedNoOp(SyncResult()),
                finishedAt: Date(timeIntervalSince1970: 200)
            )
        )
    }

    private func active(_ runID: RunID) -> RunLifecycleSnapshot {
        lifecycle(runID, phase: .active(.syncingLibrary))
    }

    private func lifecycle(_ runID: RunID, phase: RunPhase) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 100)
        return RunLifecycleSnapshot(
            runID: runID,
            requestID: RunRequestID(),
            trigger: .backgroundSync,
            intent: .observeLibrary,
            scope: .capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: "lifecycle-buffer-test"
            ),
            startedAt: startedAt,
            phase: phase
        )
    }
}

private func waitForQueuedTerminal(
    _ orchestrator: RunOrchestrator,
    after runID: RunID,
    timeout: Duration = .seconds(5)
) async throws -> RunLifecycleSnapshot {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let lifecycle = await orchestrator.currentLifecycle(),
           lifecycle.runID != runID,
           !lifecycle.isActive {
            return lifecycle
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw BufferTestError.queuedRunDidNotFinish
}

private func nextSnapshot(
    from iterator: SnapshotIterator,
    timeout: Duration = .seconds(5)
) async throws -> RunLifecycleSnapshot? {
    try await withThrowingTaskGroup(of: RunLifecycleSnapshot?.self) { group in
        group.addTask {
            await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw BufferTestError.snapshotTimedOut
        }

        let snapshotResult = try await group.next()
        group.cancelAll()
        guard let snapshotResult else { return nil }
        return snapshotResult
    }
}

private enum BufferTestError: Error, Equatable {
    case queuedRunDidNotFinish
    case snapshotTimedOut
}

private final class SnapshotIterator: @unchecked Sendable {
    /// Calls are serialized; unchecked Sendable only permits capture by the timeout task group.
    private var iterator: LifecycleUpdates.AsyncIterator

    init(updates: LifecycleUpdates) {
        iterator = updates.makeAsyncIterator()
    }

    func next() async -> RunLifecycleSnapshot? {
        await iterator.next()
    }
}

private actor CheckpointRunGate {
    private var isEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        isEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
