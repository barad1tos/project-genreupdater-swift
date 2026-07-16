import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator write runs")
struct WriteTests {
    @Test("write run preserves its submitted input")
    func writeRunPreservesInput() async throws {
        let probe = WriteRecordProbe()
        let sync = WriteSyncProbe()
        let target = writeTarget()
        let input = writeInput(target: target, artists: ["Björk"], knownTrackCount: 12)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await sync.run() },
            persistRunRecord: { try await probe.append($0) },
            writeFixPlan: { try await writer.apply(input: $0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(await writer.calls == [input])
        #expect(await sync.callCount == 0)

        let final = try #require(await probe.records.last)
        #expect(final.intent == .writeFixes)
        #expect(final.scope == input.scope)
        #expect(final.syncSummary?.modified == 1)
        #expect(final.transitions.map(\.state) == [
            .created,
            .writing,
            .verifying,
            .reporting,
            .completed,
        ])
    }

    @Test("write run fails when reviewed writes partially fail")
    func writeFailsPartialFailure() async throws {
        let probe = WriteRecordProbe()
        let target = writeTarget()
        let input = writeInput(target: target, artists: ["Björk"], knownTrackCount: 12)
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: ["track-2"],
            errorDescriptions: ["Failed to write genre for track track-2"]
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            writeFixPlan: { try await writer.apply(input: $0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        #expect(await writer.calls == [input])

        let final = try #require(await probe.records.last)
        #expect(final.intent == .writeFixes)
        #expect(final.failureMessage?.contains("Write run partially failed") == true)
        #expect(final.failureMessage?.contains("Failed to write genre for track track-2") == true)
        #expect(final.syncSummary == nil)
        #expect(final.transitions.map(\.state) == [
            .created,
            .writing,
            .reporting,
            .failed,
        ])
    }

    @Test("write run without a writer fails before shared sync")
    func writeWithoutRunnerFails() async throws {
        let probe = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await probe.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: writeInput()))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }

        let final = try #require(await probe.records.last)
        #expect(final.failureMessage == "Fix plan write runner is unavailable")
        #expect(final.transitions.map(\.state) == [
            .created,
            .writing,
            .reporting,
            .failed,
        ])
    }

    @Test("different queued write targets run in FIFO order")
    func queuedWritesRunInOrder() async {
        let syncGate = WriteSyncGate()
        let writer = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await syncGate.sync() },
            persistRunRecord: { _ in },
            writeFixPlan: { try await writer.apply(input: $0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let firstTarget = writeTarget()
        let secondTarget = writeTarget()
        let firstInput = writeInput(target: firstTarget)
        let secondInput = writeInput(target: secondTarget)

        let active = Task {
            await orchestrator.submit(RunRequest.observation(
                trigger: .backgroundSync,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await syncGate.waitUntilCount(1)

        let firstQueue = await orchestrator.submit(.manualWrite(input: firstInput))
        let secondQueue = await orchestrator.submit(.manualWrite(input: secondInput))

        guard case .queued = firstQueue, case .queued = secondQueue else {
            Issue.record("Expected both write targets to queue")
            return
        }

        await syncGate.release()
        _ = await active.value
        await writer.waitUntilCallCount(2)

        #expect(await writer.calls == [firstInput, secondInput])
    }
}

private actor WriteProbe {
    private(set) var calls: [FixPlanWriteInput] = []
    private let result: BatchUpdateResult
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    init(result: BatchUpdateResult) {
        self.result = result
    }

    func apply(input: FixPlanWriteInput) throws -> BatchUpdateResult {
        calls.append(input)
        resumeContinuations()
        return result
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

private actor WriteRecordProbe {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) throws {
        records.append(record)
    }
}

private actor WriteSyncProbe {
    private(set) var callCount = 0

    func run() -> SyncResult {
        callCount += 1
        return SyncResult()
    }
}

private actor WriteSyncGate {
    private var count = 0
    private var isReleased = false
    private var countContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func sync() async -> SyncResult {
        count += 1
        resumeCountContinuations()
        if count == 1 {
            await waitUntilReleased()
        }
        return SyncResult()
    }

    func waitUntilCount(_ target: Int) async {
        if count >= target {
            return
        }

        await withCheckedContinuation { continuation in
            countContinuations.append((target, continuation))
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }

    private func waitUntilReleased() async {
        if isReleased {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    private func resumeCountContinuations() {
        var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in countContinuations {
            if count >= target {
                continuation.resume()
            } else {
                waiting.append((target, continuation))
            }
        }
        countContinuations = waiting
    }
}

private func writeTarget() -> FixPlanWriteTarget {
    FixPlanWriteTarget(
        planID: FixPlanID(),
        planRevision: .initial,
        decisionRevision: .initial
    )
}

private func writeInput(
    target: FixPlanWriteTarget = writeTarget(),
    artists: [String] = [],
    knownTrackCount: Int? = nil
) -> FixPlanWriteInput {
    let capturedAt = Date(timeIntervalSince1970: 90)
    return FixPlanWriteInput(
        target: target,
        scope: .capture(
            requestedTestArtists: artists,
            knownTrackCount: knownTrackCount,
            createdAt: capturedAt,
            reason: "write-test"
        )
    )
}

private func writeEntry() -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .genreUpdate,
        trackID: "track-1",
        artist: "Björk",
        trackName: "Jóga",
        albumName: "Homogenic"
    )
    entry.oldGenre = "Alternative"
    entry.newGenre = "Art Pop"
    return entry
}
