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

    @Test("a pre-runner terminal lands on the failure, not a stuck screen")
    func preRunnerTerminalLandsOnFailure() async throws {
        let fixture = makeWorkflowFixture(configure: { options in
            options.failRunRecordPersistence = true
        })
        let viewModel = fixture.viewModel

        viewModel.startBatchProcessing(tracks: [
            Track(id: "t1", name: "Song", artist: "Artist", album: "Album"),
        ])
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.pendingBatchExecution == nil)
    }

    @Test("the stash survives a queued submission and the batch executes")
    func stashSurvivesQueuedSubmissionAndExecutes() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        await fixture.observationGate.arm()
        let observation = Task {
            await fixture.orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await fixture.observationGate.waitUntilEntered()

        viewModel.startBatchProcessing(tracks: [
            Track(id: "q1", name: "Song", artist: "Artist", album: "Album"),
        ])
        await viewModel.processingTask?.value
        #expect(viewModel.pendingBatchExecution != nil)

        await fixture.observationGate.release()
        _ = await observation.value
        try await waitForTerminalPhase(viewModel)

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.pendingBatchExecution == nil)
    }

    @Test("cancelling a queued batch records an honest cancelled run")
    func cancellingQueuedBatchRecordsCancelledRun() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        await fixture.observationGate.arm()
        let observation = Task {
            await fixture.orchestrator.submit(.manualObservation(requestedTestArtists: [], knownTrackCount: nil))
        }
        await fixture.observationGate.waitUntilEntered()

        viewModel.startBatchProcessing(tracks: [
            Track(id: "c1", name: "Song", artist: "Artist", album: "Album"),
        ])
        await viewModel.processingTask?.value
        viewModel.cancel()

        guard case .configure = viewModel.phase else {
            Issue.record("Expected configure phase after cancel, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.pendingBatchExecution == nil)

        await fixture.observationGate.release()
        _ = await observation.value
        try await Task.sleep(for: .milliseconds(200))

        // Cancel either purged the trigger (no batch run at all) or the
        // fallback recorded cancelled — never a completed/failed run the
        // user did not want.
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        // The append-only collector may retain the fallback path's OPEN
        // preflight row; only a terminal row other than cancelled would
        // betray an unwanted run.
        #expect(batchRecords.allSatisfy { $0.finishedAt == nil || $0.state == .cancelled })
    }

    @Test("apply-accepted flows through the orchestrator to a record")
    func applyAcceptedFlowsThroughOrchestratorToRecord() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "apply-1", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        guard case .done = viewModel.phase else {
            Issue.record("Expected done phase, got \(viewModel.phase)")
            return
        }
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        #expect(batchRecords.last?.state == .completed)
        #expect(viewModel.pendingBatchExecution == nil)
    }

    @Test("an uncertain apply leaves recovery to the orchestrator")
    func uncertainApplyLeavesRecoveryToOrchestrator() async throws {
        let fixture = makeWorkflowFixture(configure: { options in
            options.outcomeTrackIDs = ["apply-unknown"]
        })
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "apply-unknown", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        guard case .error = viewModel.phase else {
            Issue.record("Expected error phase, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.recoveryHoldID == nil)
        #expect(await fixture.batchProcessor.recoveryHoldID() != nil)
        let batchRecords = await fixture.runRecords.records.filter { $0.intent == .batchUpdate }
        #expect(batchRecords.last?.state == .recoverable)
    }

    @Test("the batch request carries the configured test-artist scope")
    func batchRequestCarriesTestArtistScope() async throws {
        let dependencies = makeBatchTestDependencies()
        dependencies.config.development.testArtists = ["Clutch"]
        let records = RecordCollector()
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await records.append($0) },
            runBatchUpdate: dependencies.makeBatchRunnerBridge()
        )))
        dependencies.batchRunProvider = { _, _ in
            BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
        }

        _ = try await dependencies.submitBatchRun(
            input: BatchRunInput(options: UpdateOptions(), trackCount: 1)
        )

        #expect(await records.records.first?.scope.source == .testArtists)
    }

    private func waitForTerminalPhase(
        _ viewModel: WorkflowViewModel,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch viewModel.phase {
            case .done, .error, .configure:
                return
            default:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("Timed out waiting for a terminal phase; last: \(viewModel.phase)")
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
