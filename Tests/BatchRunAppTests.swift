import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

/// D3 (slice 12): the orchestrator's batch runner bridge reaches the
/// registered live provider, and a windowless submit fails fast with an
/// honest record instead of running blind.
@Suite("Batch run app wiring")
@MainActor
struct BatchRunAppTests {
    @Test("a submitted batch reaches the registered provider and records")
    func submittedBatchReachesProviderAndRecords() async throws {
        let dependencies = makeBatchTestDependencies()
        let records = RecordCollector()
        let received = ReceivedRunBox()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) },
            runBatchUpdate: dependencies.makeBatchRunnerBridge()
        )))
        dependencies.batchRunProvider = { _, runID in
            received.runID = runID
            return BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
        }

        let result = try await dependencies.submitBatchRun(
            input: BatchRunInput(options: UpdateOptions(), trackCount: 2)
        )

        guard case .completedNoOp = result else {
            Issue.record("Expected completedNoOp, got \(result)")
            return
        }
        let stored = await records.records
        #expect(stored.first?.intent == .batchUpdate)
        #expect(stored.first?.finishedAt == nil)
        #expect(stored.last?.finishedAt != nil)
        #expect(received.runID == stored.last?.runID)
    }

    @Test("an unregistered provider fails the batch run fast")
    func unregisteredProviderFailsBatchFast() async throws {
        let dependencies = makeBatchTestDependencies()
        let records = RecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) },
            runBatchUpdate: dependencies.makeBatchRunnerBridge()
        )))

        let result = try await dependencies.submitBatchRun(
            input: BatchRunInput(options: UpdateOptions(), trackCount: 2)
        )

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        let terminal = await records.records.last
        #expect(terminal?.failureMessage?.contains("Batch runner is unavailable") == true)
    }

    private func makeBatchTestDependencies() -> AppDependencies {
        AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to these wiring pins.
            }
        )
    }
}

private actor RecordCollector {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

/// The provider closure is @MainActor; a plain box keeps the received
/// run ID observable without crossing isolation.
@MainActor
private final class ReceivedRunBox {
    var runID: RunID?
}
