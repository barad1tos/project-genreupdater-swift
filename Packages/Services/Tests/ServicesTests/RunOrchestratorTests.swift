import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator")
struct RunOrchestratorTests {
    @Test("manual observation captures immutable test artist scope")
    func manualObservationCapturesScope() async {
        let clock = ClockProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
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
            persistRunRecord: { _ in },
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
            persistRunRecord: { _ in },
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

    @Test("cancellation error during sync fails the run with a cancelled message")
    func cancellationDuringSyncFailsRunWithCancelledMessage() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                throw CancellationError()
            },
            persistRunRecord: { _ in },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        #expect(result.lifecycle.state == .failed)
        #expect(result.lifecycle.failureMessage == "Run cancelled")
    }

    @Test("manual observation rejects a second active run")
    func manualObservationRejectsSecondActiveRun() async {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: { _ in },
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

        guard case .alreadyRunning = second else {
            Issue.record("Expected alreadyRunning, got \(second)")
            return
        }
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
            persistRunRecord: { _ in },
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
            persistRunRecord: { _ in },
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let stream = await orchestrator.lifecycleUpdates()
        let observer = Task {
            for await _ in stream {}
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

    @Test("preview run syncs first, plans fixes, and persists preview intent")
    func previewProducesPlan() async throws {
        let clock = ClockProbe()
        let probe = RunRecordProbe()
        let producer = FixPlanProducerProbe(production: FixPlanProduction(
            planID: FixPlanID(),
            proposalCount: 2
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            produceFixPlan: { try await producer.produce(runID: $0, scope: $1) },
            now: { clock.now() }
        ))

        let result = await orchestrator.submit(.manualPreview(
            requestedTestArtists: [" Aphex Twin "],
            knownTrackCount: 75
        ))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }

        let call = try #require(await producer.calls.first)
        #expect(call.runID == result.lifecycle.runID)
        #expect(call.scope == result.lifecycle.scope)

        let final = try #require(await probe.records.last)
        #expect(final.intent == .previewFixes)
        #expect(final.transitions.map(\.state) == [
            .created,
            .syncingLibrary,
            .planningFixes,
            .reporting,
            .completed,
        ])
        #expect(final.syncSummary?.changeCount == 0)
        #expect(final.finishedAt == result.lifecycle.finishedAt)
    }

    @Test("preview run with an empty production finishes no-op even when sync changed")
    func previewEmptyFinishesNoOp() async throws {
        let probe = RunRecordProbe()
        let producer = FixPlanProducerProbe(production: .empty)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: { try await probe.append($0) },
            produceFixPlan: { try await producer.produce(runID: $0, scope: $1) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .completedNoOp = result else {
            Issue.record("Expected completedNoOp, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.state == .completedNoOp)
        #expect(final.syncSummary?.changeCount == 1)
        #expect(final.transitions.map(\.state) == [
            .created,
            .syncingLibrary,
            .planningFixes,
            .reporting,
            .completedNoOp,
        ])
    }

    @Test("preview run records producer failures after the planning stage")
    func producerFailureFailsPreview() async throws {
        let probe = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            produceFixPlan: { _, _ in throw ProbeError(message: "Plan store unavailable") },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.state == .failed)
        #expect(final.failureMessage == "Plan store unavailable")
        #expect(final.transitions.map(\.state) == [
            .created,
            .syncingLibrary,
            .planningFixes,
            .reporting,
            .failed,
        ])
    }

    @Test("preview run records producer cancellation after the planning stage")
    func planningCancellationFails() async throws {
        let probe = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            produceFixPlan: { _, _ in throw CancellationError() },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.state == .failed)
        #expect(final.failureMessage == "Run cancelled")
        #expect(final.transitions.map(\.state) == [
            .created,
            .syncingLibrary,
            .planningFixes,
            .reporting,
            .failed,
        ])
    }

    @Test("preview run without a producer fails fast after sync")
    func previewWithoutProducerFails() async throws {
        let probe = RunRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.failureMessage == "Fix plan producer is unavailable")
        #expect(final.transitions.map(\.state) == [
            .created,
            .syncingLibrary,
            .reporting,
            .failed,
        ])
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
            produceFixPlan: { try await producer.produce(runID: $0, scope: $1) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        #expect(result.lifecycle.state == .completedNoOp)
        #expect(await producer.calls.isEmpty)
        let final = try #require(await probe.records.last)
        #expect(final.transitions.map(\.state) == [.created, .syncingLibrary, .reporting, .completedNoOp])
    }

    @Test("active preview run rejects overlapping submissions")
    func previewRejectsOverlap() async {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in
                // This overlap test does not inspect persisted run history.
            },
            produceFixPlan: { _, _ in
                await gate.waitUntilReleased()
                return .empty
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let first = Task {
            await orchestrator.submit(.manualPreview(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        let second = await orchestrator.submit(.manualPreview(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        await gate.release()
        _ = await first.value

        guard case let .alreadyRunning(snapshot) = second else {
            Issue.record("Expected alreadyRunning, got \(second)")
            return
        }
        #expect(snapshot.state == .planningFixes)
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
            persistRunRecord: { _ in },
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let iterator = await LifecycleIterator(stream: orchestrator.lifecycleUpdates())

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

        let replayIterator = await LifecycleIterator(stream: orchestrator.lifecycleUpdates())
        let replayed = try await nextLifecycleSnapshot(from: replayIterator)

        #expect(replayed == snapshot)
    }

    @Test("submit after a failed run is accepted, not already running")
    func submitAfterFailedRunIsAccepted() async {
        let toggle = SyncOutcomeToggle()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { try await toggle.syncOrFail() },
            persistRunRecord: { _ in },
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
        if await orchestrator.lifecycleSubscriptionCountForTesting() == expected {
            return
        }
        await Task.yield()
    }

    Issue.record("Expected \(expected) lifecycle subscriptions")
}

private final class LifecycleIterator: @unchecked Sendable {
    private var iterator: AsyncStream<RunLifecycleSnapshot>.Iterator

    init(stream: AsyncStream<RunLifecycleSnapshot>) {
        iterator = stream.makeAsyncIterator()
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

private final class ClockProbe: @unchecked Sendable {
    private var timestamp: TimeInterval = 100

    func now() -> Date {
        defer { timestamp += 1 }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private struct FixPlanProducerCall: Equatable {
    let runID: RunID
    let scope: ProcessingScopeSnapshot
}

private actor FixPlanProducerProbe {
    private(set) var calls: [FixPlanProducerCall] = []
    private let production: FixPlanProduction

    init(production: FixPlanProduction) {
        self.production = production
    }

    func produce(runID: RunID, scope: ProcessingScopeSnapshot) throws -> FixPlanProduction {
        calls.append(FixPlanProducerCall(runID: runID, scope: scope))
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
