import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator preview runs")
struct RunPreviewTests {
    @Test("queued preview starts with pending request scope")
    func previewUsesPending() async throws {
        let gate = PreviewGate()
        let syncCalls = PreviewSyncProbe()
        let producer = PreviewProducerProbe(production: .empty)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await syncCalls.recordCall()
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignorePreviewRecord,
            produceFixPlan: { try await producer.produce(runID: $0, scope: $1) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let first = Task {
            await orchestrator.submit(RunRequest(
                trigger: .backgroundSync,
                intent: .observeLibrary,
                requestedTestArtists: ["Artist A"],
                knownTrackCount: 12
            ))
        }
        await syncCalls.waitUntilCount(1)

        let previewRequest = RunRequest(
            trigger: .manualCheck,
            intent: .previewFixes,
            requestedTestArtists: [" Artist B "],
            knownTrackCount: 44
        )
        let second = await orchestrator.submit(previewRequest)
        guard case .queued = second else {
            Issue.record("Expected queued, got \(second)")
            return
        }

        await gate.release()
        _ = await first.value
        await syncCalls.waitUntilCount(2)
        await producer.waitUntilCallCount(1)

        let call = try #require(await producer.calls.first)
        #expect(call.scope.source == .testArtists)
        #expect(call.scope.normalizedTestArtists == ["Artist B"])
        #expect(call.scope.knownTrackCount == 44)
    }

    @Test("preview run syncs first, plans fixes, and persists preview intent")
    func previewProducesPlan() async throws {
        let clock = PreviewClock()
        let probe = PreviewRecordProbe()
        let producer = PreviewProducerProbe(production: FixPlanProduction(
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
        let probe = PreviewRecordProbe()
        let producer = PreviewProducerProbe(production: .empty)
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
        let probe = PreviewRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            produceFixPlan: { _, _ in throw PreviewError(message: "Plan store unavailable") },
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
    func planningCancellationCancels() async throws {
        let probe = PreviewRecordProbe()
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

        guard case .cancelled = result else {
            Issue.record("Expected cancelled, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.state == .cancelled)
        #expect(final.failureMessage == "Run cancelled")
        #expect(final.transitions.map(\.state) == [
            .created,
            .syncingLibrary,
            .planningFixes,
            .reporting,
            .cancelled,
        ])
    }

    @Test("preview run without a producer fails fast after sync")
    func previewWithoutProducerFails() async throws {
        let probe = PreviewRecordProbe()
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
}

private struct PreviewProducerCall: Equatable {
    let runID: RunID
    let scope: ProcessingScopeSnapshot
}

private actor PreviewProducerProbe {
    private(set) var calls: [PreviewProducerCall] = []
    private let production: FixPlanProduction
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    init(production: FixPlanProduction) {
        self.production = production
    }

    func produce(runID: RunID, scope: ProcessingScopeSnapshot) throws -> FixPlanProduction {
        calls.append(PreviewProducerCall(runID: runID, scope: scope))
        resumeContinuations()
        return production
    }

    func waitUntilCallCount(_ target: Int) async {
        if calls.count >= target {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append((target, continuation))
        }
    }

    private func resumeContinuations() {
        var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in continuations {
            if calls.count >= target {
                continuation.resume()
            } else {
                waiting.append((target, continuation))
            }
        }
        continuations = waiting
    }
}

private final class PreviewClock: @unchecked Sendable {
    private var timestamp: TimeInterval = 100

    func now() -> Date {
        defer { timestamp += 1 }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private actor PreviewRecordProbe {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) throws {
        records.append(record)
    }
}

private actor PreviewSyncProbe {
    private var count = 0
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func recordCall() {
        count += 1
        resumeContinuations()
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

private actor PreviewGate {
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
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
}

private struct PreviewError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private func ignorePreviewRecord(_ record: RunRecord) async throws {
    _ = record
}
