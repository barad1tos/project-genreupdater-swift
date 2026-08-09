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

    @Test("a full-library batch flows through the orchestrator to done")
    func fullLibraryBatchFlowsThroughOrchestratorToDone() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.updateGenre = true
        viewModel.updateYear = false

        viewModel.startBatchProcessing(tracks: [
            Track(id: "batch-1", name: "Song", artist: "Artist", album: "Album", genre: "Old"),
        ])
        await viewModel.processingTask?.value

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.result != nil)
        #expect(viewModel.pendingBatchExecution == nil)
    }

    @Test("an uncertain batch outcome leaves recovery to the orchestrator")
    func uncertainBatchOutcomeLeavesRecoveryToOrchestrator() async throws {
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            configure: { options in
                options.outcomeTrackIDs = ["unknown-batch"]
            }
        )
        let viewModel = fixture.viewModel
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.startBatchProcessing(tracks: [batchYearTrack(id: "unknown-batch")])
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
        // Ownership moved: the run's recovery hold lives with the
        // orchestrator's processor call, not a second view-model hold.
        #expect(viewModel.recoveryHoldID == nil)
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
