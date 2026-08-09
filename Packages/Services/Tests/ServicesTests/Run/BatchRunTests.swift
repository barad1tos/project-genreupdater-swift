import Core
import Foundation
import Testing
@testable import Services

/// D1/D2 (slice 12): the full-library batch is a first-class run kind —
/// every batch leaves an open→terminal record pair, uncertain script
/// outcomes route to recovery through the same processor hold, and the
/// arbiter ranks a batch as a mutating run.
@Suite("Batch runs")
struct BatchRunTests {
    private func batchInput(trackCount: Int = 3) -> BatchRunInput {
        BatchRunInput(options: UpdateOptions(), trackCount: trackCount)
    }

    private func manualBatch(trackCount: Int = 3) -> RunRequest {
        .manualBatchUpdate(
            input: batchInput(trackCount: trackCount),
            requestedTestArtists: [],
            knownTrackCount: trackCount
        )
    }

    @Test("a batch run persists an open record and a completed terminal")
    func batchRunPersistsOpenAndTerminalRecords() async throws {
        let records = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            runBatchUpdate: { _, _ in
                BatchUpdateResult(
                    entries: [writeEntry(), writeEntry()],
                    noOpEntries: [writeEntry()],
                    failedTrackIDs: [],
                    errorDescriptions: []
                )
            }
        ))

        let result = await orchestrator.submit(manualBatch())

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        let stored = await records.records
        let open = try #require(stored.first)
        #expect(open.intent == .batchUpdate)
        #expect(open.finishedAt == nil)
        let terminal = try #require(stored.last)
        #expect(terminal.state == .completed)
        #expect(terminal.writeSummary == RunWriteSummary(applied: 2, verifiedNoOp: 1, failed: 0))
    }

    @Test("an empty batch finishes as a no-op record")
    func emptyBatchIsNoOp() async throws {
        let records = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            runBatchUpdate: { _, _ in
                BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
            }
        ))

        let result = await orchestrator.submit(manualBatch())

        guard case .completedNoOp = result else {
            Issue.record("Expected completedNoOp, got \(result)")
            return
        }
        let terminal = try #require(await records.records.last)
        #expect(terminal.state == .completedNoOp)
    }

    @Test("partial failures finish failed with the write summary intact")
    func partialFailuresFinishFailedWithSummary() async throws {
        let records = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            runBatchUpdate: { _, _ in
                BatchUpdateResult(
                    entries: [writeEntry()],
                    failedTrackIDs: ["track-2"],
                    errorDescriptions: ["Music.app rejected the write"]
                )
            }
        ))

        let result = await orchestrator.submit(manualBatch())

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        let terminal = try #require(await records.records.last)
        #expect(terminal.state == .failed)
        #expect(terminal.writeSummary == RunWriteSummary(applied: 1, verifiedNoOp: 0, failed: 1))
    }

    @Test("a missing batch runner fails the run fast")
    func missingRunnerFailsFast() async throws {
        let records = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) }
        ))

        let result = await orchestrator.submit(manualBatch())

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        let terminal = try #require(await records.records.last)
        #expect(terminal.failureMessage?.contains("Batch update runner is unavailable") == true)
    }

    @Test("an uncertain script outcome routes the batch to recovery")
    func scriptOutcomeRoutesToRecovery() async throws {
        let records = WriteRecordProbe()
        let holdProbe = HoldProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: RunOrchestrator.WriteDependencies(
                beginRecoveryHold: { await holdProbe.begin() }
            ),
            runBatchUpdate: { _, _ in
                throw AppleScriptOutcomeError(scriptName: "batch_update_tracks", duration: .seconds(3))
            }
        ))

        let result = await orchestrator.submit(manualBatch())

        guard case .recoverable = result else {
            Issue.record("Expected recoverable, got \(result)")
            return
        }
        #expect(await holdProbe.callCount == 1)
        let terminal = try #require(await records.records.last)
        #expect(terminal.state == .recoverable)
    }

    @Test("a cancelled batch finishes as a cancelled record")
    func cancellationFinishesCancelled() async throws {
        let records = WriteRecordProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            runBatchUpdate: { _, _ in throw CancellationError() }
        ))

        let result = await orchestrator.submit(manualBatch())

        guard case .cancelled = result else {
            Issue.record("Expected cancelled, got \(result)")
            return
        }
        let terminal = try #require(await records.records.last)
        #expect(terminal.state == .cancelled)
    }

    @Test("a batch queues behind an active observation")
    func batchQueuesBehindActiveObservation() async throws {
        let gate = WriteSyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { await gate.sync() },
            persistRunRecord: ignoreRunRecord,
            runBatchUpdate: { _, _ in
                BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
            }
        ))

        let observation = Task {
            await orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await gate.waitUntilCount(1)
        let queued = await orchestrator.submit(manualBatch())
        guard case let .queued(activeRun) = queued else {
            Issue.record("Expected queued, got \(queued)")
            return
        }

        await gate.release()
        _ = await observation.value
        let terminal = try await waitForBatchTerminal(orchestrator, after: activeRun.runID)
        #expect(terminal.intent == .batchUpdate)
        #expect(terminal.state == .completedNoOp)
    }

    @Test("an identical batch resubmit is already covered")
    func identicalBatchIsAlreadyCovered() async throws {
        let runnerGate = RunnerGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            runBatchUpdate: { _, _ in
                await runnerGate.wait()
                return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
            }
        ))

        let first = Task { await orchestrator.submit(manualBatch()) }
        await runnerGate.waitUntilEntered()
        let second = await orchestrator.submit(manualBatch())
        guard case .alreadyCovered = second else {
            Issue.record("Expected alreadyCovered, got \(second)")
            return
        }

        await runnerGate.release()
        _ = await first.value
    }

    @Test("a batch and a plan write queue independently")
    func batchAndPlanWriteQueueIndependently() async throws {
        let runnerGate = RunnerGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            write: RunOrchestrator.WriteDependencies(
                writeFixPlan: { _, _, _ in
                    BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
                }
            ),
            runBatchUpdate: { _, _ in
                await runnerGate.wait()
                return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
            }
        ))

        let batch = Task { await orchestrator.submit(manualBatch()) }
        await runnerGate.waitUntilEntered()
        let write = await orchestrator.submit(.manualWrite(input: writeInput()))
        guard case .queued = write else {
            Issue.record("Expected queued, got \(write)")
            return
        }

        await runnerGate.release()
        _ = await batch.value
    }

    @Test("a batch record round-trips through the store")
    func batchRecordRoundTripsThroughStore() async throws {
        let store = try makeRunStore()
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(intent: .batchUpdate)
        )

        try await store.upsert(record)

        let fetched = try await store.record(for: record.runID)
        let loaded = try #require(fetched)
        #expect(loaded.intent == .batchUpdate)
        #expect(loaded.state == .completed)
    }

    @Test("an unknown intent still skips as corrupted without failing the page")
    func unknownIntentSkipsAsCorrupted() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let transitions = try JSONEncoder().encode([
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
        ])
        try insertRunRow(
            runID: UUID(),
            transitionsData: transitions,
            input: RunRowInput(rawIntent: "futureIntent", state: .completed),
            into: container
        )

        let page = try await store.reports(matching: RunReportQuery())

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
    }

    private func waitForBatchTerminal(
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
        throw BatchWaitTimeout()
    }
}

private struct BatchWaitTimeout: Error {}

private func ignoreRunRecord(_: RunRecord) async throws {
    // Record persistence is irrelevant to these arbiter pins.
}

private actor HoldProbe {
    private(set) var callCount = 0

    func begin() -> UUID {
        callCount += 1
        return UUID()
    }
}

/// Holds the batch runner mid-flight so arbiter decisions against an
/// ACTIVE batch are observable.
private actor RunnerGate {
    private var isEntered = false
    private var isReleased = false
    private var enterContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isEntered = true
        for continuation in enterContinuations {
            continuation.resume()
        }
        enterContinuations = []
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if isEntered { return }
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
