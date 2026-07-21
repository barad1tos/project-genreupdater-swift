import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator")
struct OrchestratorTests {
    @Test("run audit remains monotonic when the clock moves backward")
    func clampsReversedClock() async throws {
        let clock = ReversingClockProbe()
        let records = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            now: { clock.now() }
        ))

        _ = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        let final = try #require(await records.records.last)
        let timestamps = final.transitions.map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
        #expect(final.finishedAt == timestamps.last)
    }

    @Test("manual observation captures immutable test artist scope")
    func manualObservationCapturesScope() async {
        let clock = ClockProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            now: { clock.now() }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [" Aphex Twin ", "aphex twin"],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle.state == .completedNoOp)
        #expect(result.lifecycle.scope.source == .testArtists)
        #expect(result.lifecycle.scope.normalizedTestArtists == ["Aphex Twin"])
        #expect(result.lifecycle.scope.knownTrackCount == 75)
    }

    @Test("manual observation returns completed when sync detects any delta")
    func manualObservationReturnsCompletedForDelta() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: 35224
        ))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(result.lifecycle.state == .completed)
        #expect(result.lifecycle.syncResult?.changeCount == 1)
    }

    @Test("manual observation stores failed lifecycle")
    func manualObservationStoresFailure() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                throw ProbeError(message: "Music.app unavailable")
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        #expect(result.lifecycle.state == .failed)
        #expect(result.lifecycle.failureMessage == "Music.app unavailable")
    }

    @Test("cancellation error during sync cancels the run with a cancelled message")
    func cancellationDuringSyncCancelsRunWithCancelledMessage() async throws {
        let probe = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                throw CancellationError()
            },
            persistRunRecord: { try await probe.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .cancelled = result else {
            Issue.record("Expected cancelled, got \(result)")
            return
        }
        #expect(result.lifecycle.state == .cancelled)
        #expect(result.lifecycle.failureMessage == "Run cancelled")

        let final = try #require(await probe.records.last)
        #expect(final.state == .cancelled)
        #expect(final.failureMessage == "Run cancelled")
        #expect(final.finishedAt != nil)
        #expect(final.transitions.map(\.state) == [.created, .syncingLibrary, .reporting, .cancelled])
    }

    @Test("manual observation covers duplicate active run")
    func manualCoversDuplicate() async {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let first = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        let second = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        await gate.release()
        _ = await first.value

        guard case .alreadyCovered = second else {
            Issue.record("Expected alreadyCovered, got \(second)")
            return
        }
    }

    @Test("manual observation queues behind active background sync")
    func manualQueuesAfterBackground() async {
        let gate = SyncGate()
        let syncCalls = SyncCallProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await syncCalls.recordCall()
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let first = Task {
            await orchestrator.submit(RunRequest.observation(
                trigger: .backgroundSync,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncCalls.waitUntilCount(1)

        let second = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        guard case .queued = second else {
            Issue.record("Expected queued, got \(second)")
            return
        }

        await gate.release()
        _ = await first.value
        await syncCalls.waitUntilCount(2)
    }

    @Test("manual observation queues after active background sync failure")
    func manualQueuesAfterBackgroundFailure() async {
        let gate = SyncGate()
        let syncCalls = SyncCallProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                let callIndex = await syncCalls.recordCall()
                await gate.waitUntilReleased()
                if callIndex == 1 {
                    throw ProbeError(message: "Music.app unavailable")
                }
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let first = Task {
            await orchestrator.submit(RunRequest.observation(
                trigger: .backgroundSync,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncCalls.waitUntilCount(1)

        let second = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        guard case .queued = second else {
            Issue.record("Expected queued, got \(second)")
            return
        }

        await gate.release()
        let firstResult = await first.value
        guard case .failed = firstResult else {
            Issue.record("Expected failed, got \(firstResult)")
            return
        }
        await syncCalls.waitUntilCount(2)
        #expect(await orchestrator.currentLifecycle()?.trigger == .manualCheck)
    }

    @Test("lifecycle stream preserves terminal snapshot before queued run")
    func lifecycleStreamPreservesTerminalBeforeQueuedRun() async throws {
        let gate = SyncGate()
        let syncCalls = SyncCallProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await syncCalls.recordCall()
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let iterator = await LifecycleIterator(updates: orchestrator.lifecycleUpdates())

        let first = Task {
            await orchestrator.submit(RunRequest.observation(
                trigger: .backgroundSync,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncCalls.waitUntilCount(1)

        let second = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        guard case .queued = second else {
            Issue.record("Expected queued, got \(second)")
            return
        }

        await gate.release()
        let firstResult = await first.value
        await syncCalls.waitUntilCount(2)

        let firstRunID = firstResult.lifecycle.runID
        var snapshots: [RunLifecycleSnapshot] = []
        while let snapshot = try await nextLifecycleSnapshot(from: iterator) {
            snapshots.append(snapshot)
            if snapshot.runID != firstRunID, snapshot.isActive {
                break
            }
        }

        let firstTerminalIndex = try #require(snapshots.firstIndex {
            $0.runID == firstRunID && !$0.isActive
        })
        let queuedActiveIndex = try #require(snapshots.firstIndex {
            $0.runID != firstRunID && $0.isActive
        })
        #expect(firstTerminalIndex < queuedActiveIndex)
    }

    @Test("Recovery changes stay behind an active lifecycle")
    func keepsRecoveryHidden() async throws {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord
        ))
        let active = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()
        let activeRunID = try #require(await orchestrator.activeLifecycle()?.runID)
        let iterator = await LifecycleIterator(updates: orchestrator.lifecycleUpdates())

        let replayed = try await nextLifecycleSnapshot(from: iterator)
        #expect(replayed?.runID == activeRunID)

        let recovery = recoveryRecord()
        await orchestrator.restoreRecovery(recovery)
        await orchestrator.resolveRecovery(runID: recovery.runID, at: Date(timeIntervalSince1970: 200))
        await gate.release()
        _ = await active.value

        var snapshots: [RunLifecycleSnapshot] = []
        while let snapshot = try await nextLifecycleSnapshot(from: iterator) {
            snapshots.append(snapshot)
            if snapshot.runID == activeRunID, !snapshot.isActive {
                break
            }
        }
        #expect(snapshots.allSatisfy { $0.runID == activeRunID })
    }

    @Test("lifecycle stream bounds buffered checkpoint snapshots")
    func boundsLifecycleBuffer() async throws {
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            write: .init(writeFixPlan: { _, checkpoint in
                for _ in 0 ..< RunOrchestrator.lifecycleBufferLimit * 2 {
                    try await checkpoint(.beforeAttempt([itemID]))
                }
                try await checkpoint(.afterAttempt([itemID]))
                try await checkpoint(.afterVerification([itemID: .written]))
                return BatchUpdateResult(entries: [writeEntry()], failedTrackIDs: [], errorDescriptions: [])
            })
        ))
        let iterator = await LifecycleIterator(updates: orchestrator.lifecycleUpdates())

        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))

        var buffered = 0
        while let snapshot = try await nextLifecycleSnapshot(from: iterator) {
            buffered += 1
            if !snapshot.isActive {
                break
            }
        }
        #expect(buffered <= RunOrchestrator.lifecycleBufferLimit)
    }

    @Test("cancelling the submitter does not fail the active run")
    func cancellingSubmitterDoesNotFailActiveRun() async {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                try Task.checkCancellation()
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let submitter = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()
        submitter.cancel()
        await gate.release()

        let result = await submitter.value
        #expect(result.lifecycle.state == .completedNoOp)
        #expect(await orchestrator.currentLifecycle()?.state == .completedNoOp)
    }

    @Test("lifecycle updates unregister subscriber after cancellation")
    func lifecycleUpdatesUnregisterSubscriberAfterCancellation() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let stream = await orchestrator.lifecycleUpdates()
        let observer = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        await waitForSubscriptionCount(orchestrator, expected: 1)
        observer.cancel()
        _ = await observer.result
        await waitForSubscriptionCount(orchestrator, expected: 0)
    }

    @Test("successful run persists an open record and a final record")
    func successfulRunPersistsOpenAndFinalRecords() async throws {
        let clock = ClockProbe()
        let probe = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: { try await probe.append($0) },
            now: { clock.now() }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: 75
        ))

        let records = await probe.records
        #expect(records.count == 2)

        let open = try #require(records.first)
        #expect(open.state == .syncingLibrary)
        #expect(open.finishedAt == nil)
        #expect(open.syncSummary == nil)
        #expect(open.transitions.map(\.state) == [.created, .syncingLibrary])

        let final = try #require(records.last)
        #expect(final.runID == open.runID)
        #expect(final.state == .completed)
        #expect(final.transitions.map(\.state) == [.created, .syncingLibrary, .reporting, .completed])
        #expect(final.syncSummary?.changeCount == 1)
        #expect(final.finishedAt == result.lifecycle.finishedAt)
        #expect(final.startedAt == result.lifecycle.startedAt)
        #expect(final.failureMessage == nil)
    }

    @Test("manual observation never calls the fix plan producer")
    func observationSkipsProducer() async throws {
        let probe = RunRecordProbe()
        let producer = FixPlanProducerProbe(production: FixPlanProduction(
            planID: FixPlanID(),
            proposalCount: 1
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            produceFixPlan: { runID, scope, _ in
                try await producer.produce(runID: runID, scope: scope)
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        #expect(result.lifecycle.state == .completedNoOp)
        #expect(await producer.callCount == 0)
        let final = try #require(await probe.records.last)
        #expect(final.transitions.map(\.state) == [.created, .syncingLibrary, .reporting, .completedNoOp])
    }

    @Test("failed run persists a failure record")
    func failedRunPersistsFailureRecord() async throws {
        let probe = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                throw ProbeError(message: "Music.app unavailable")
            },
            persistRunRecord: { try await probe.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        _ = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        let final = try #require(await probe.records.last)
        #expect(final.state == .failed)
        #expect(final.transitions.map(\.state) == [.created, .syncingLibrary, .reporting, .failed])
        #expect(final.failureMessage == "Music.app unavailable")
        #expect(final.syncSummary == nil)
    }

    @Test("persist failure does not change the run outcome")
    func persistFailureDoesNotChangeRunOutcome() async {
        let probe = RunRecordProbe()
        await probe.setPersistError(ProbeError(message: "disk full"))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        #expect(result.lifecycle.state == .completedNoOp)
        #expect(await orchestrator.currentLifecycle()?.state == .completedNoOp)
    }

    @Test("lifecycle stream delivers a terminal snapshot and replays it to new subscribers")
    func lifecycleStreamDeliversTerminalSnapshotAndReplaysIt() async throws {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let iterator = await LifecycleIterator(updates: orchestrator.lifecycleUpdates())

        let submitTask = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()
        await gate.release()

        var terminalSnapshot: RunLifecycleSnapshot?
        while terminalSnapshot == nil {
            guard let snapshot = try await nextLifecycleSnapshot(from: iterator) else { break }
            if !snapshot.isActive {
                terminalSnapshot = snapshot
            }
        }
        _ = await submitTask.value

        let snapshot = try #require(terminalSnapshot)
        #expect(snapshot.state == .completedNoOp)

        let replayIterator = await LifecycleIterator(updates: orchestrator.lifecycleUpdates())
        let replayed = try await nextLifecycleSnapshot(from: replayIterator)

        #expect(replayed == snapshot)
    }

    @Test("submit after a failed run is accepted, not already running")
    func submitAfterFailedRunIsAccepted() async {
        let toggle = SyncOutcomeToggle()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { try await toggle.syncOrFail() },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let firstResult = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        guard case .failed = firstResult else {
            Issue.record("Expected failed, got \(firstResult)")
            return
        }
        #expect(firstResult.lifecycle.state == .failed)

        let secondResult = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .completedNoOp = secondResult else {
            Issue.record("Expected completedNoOp, got \(secondResult)")
            return
        }
    }
}

private func waitForSubscriptionCount(
    _ orchestrator: RunOrchestrator,
    expected: Int
) async {
    for _ in 0 ..< 20 {
        if await orchestrator.lifecycleSubscriberCount() == expected {
            return
        }
        await Task.yield()
    }

    Issue.record("Expected \(expected) lifecycle subscriptions")
}

private final class LifecycleIterator: @unchecked Sendable {
    private var iterator: LifecycleUpdates.AsyncIterator

    init(updates: LifecycleUpdates) {
        iterator = updates.makeAsyncIterator()
    }

    func next() async -> RunLifecycleSnapshot? {
        await iterator.next()
    }
}

private enum LifecycleStreamTestError: Error, CustomStringConvertible {
    case timedOutWaitingForSnapshot

    var description: String {
        "Timed out waiting for lifecycle snapshot"
    }
}

private func nextLifecycleSnapshot(
    from iterator: LifecycleIterator,
    timeout: Duration = .seconds(5)
) async throws -> RunLifecycleSnapshot? {
    try await withThrowingTaskGroup(of: RunLifecycleSnapshot?.self) { group in
        // LifecycleIterator is captured here; tests call next() serially and the timeout task never touches it.
        group.addTask {
            await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LifecycleStreamTestError.timedOutWaitingForSnapshot
        }

        let snapshotResult = try await group.next()
        group.cancelAll()
        guard let snapshotResult else { return nil }
        return snapshotResult
    }
}

private actor SyncOutcomeToggle {
    private var shouldFail = true

    func syncOrFail() throws -> SyncResult {
        if shouldFail {
            shouldFail = false
            throw ProbeError(message: "Music.app unavailable")
        }
        return SyncResult()
    }
}

private actor SyncCallProbe {
    private var count = 0
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    @discardableResult
    func recordCall() -> Int {
        count += 1
        resumeContinuations()
        return count
    }

    func waitUntilCount(_ target: Int) async {
        if count >= target {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append((target, continuation))
        }
    }

    private func resumeContinuations() {
        var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in continuations {
            if count >= target {
                continuation.resume()
            } else {
                waiting.append((target, continuation))
            }
        }
        continuations = waiting
    }
}

private final class ClockProbe: @unchecked Sendable {
    private var timestamp: TimeInterval = 100

    func now() -> Date {
        defer { timestamp += 1 }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private final class ReversingClockProbe: @unchecked Sendable {
    private var timestamp: TimeInterval = 100

    func now() -> Date {
        defer { timestamp -= 1 }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private actor FixPlanProducerProbe {
    private(set) var callCount = 0
    private let production: FixPlanProduction

    init(production: FixPlanProduction) {
        self.production = production
    }

    func produce(runID _: RunID, scope _: ProcessingScopeSnapshot) throws -> FixPlanProduction {
        callCount += 1
        return production
    }
}

private actor SyncGate {
    private var hasEntered = false
    private var isReleased = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if hasEntered {
            return
        }

        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilReleased() async {
        hasEntered = true
        resumeEnteredContinuations()

        if isReleased {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }

    private func resumeEnteredContinuations() {
        for continuation in enteredContinuations {
            continuation.resume()
        }
        enteredContinuations = []
    }
}

private struct ProbeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private func ignoreRunRecord(_ record: RunRecord) async throws {
    _ = record
}

private actor RunRecordProbe {
    private(set) var records: [RunRecord] = []
    private var persistError: Error?

    func append(_ record: RunRecord) throws {
        if let persistError {
            throw persistError
        }
        records.append(record)
    }

    func setPersistError(_ error: Error) {
        persistError = error
    }
}
