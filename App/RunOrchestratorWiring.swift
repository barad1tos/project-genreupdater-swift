import Core
import Foundation
import Services

/// Run-orchestrator wiring, split from the main dependencies file: the
/// closures here bridge the actor's Sendable dependency surface onto
/// main-actor services and providers.
extension AppDependencies {
    func writeDependencies(
        store: any RunRecordStore,
        processor: BatchProcessor,
        writeFixPlan: (@Sendable (
            FixPlanWriteInput,
            RunID,
            @escaping WorkCheckpointSink
        ) async throws -> BatchUpdateResult)?
    ) -> RunOrchestrator.WriteDependencies {
        RunOrchestrator.WriteDependencies(
            persistCheckpoint: { runID, checkpoint in
                try await store.checkpoint(checkpoint, runID: runID)
            },
            writeFixPlan: writeFixPlan,
            beginRecoveryHold: {
                await processor.beginRecoveryHold()
            },
            restoreRecoveryHold: { id in
                await processor.beginRecoveryHold(id: id)
            },
            clearRecoveryHold: { id in
                try await processor.clearRecovery(batchID: id)
            }
        )
    }

    func makeRunOrchestrator(
        syncService: LibrarySyncService,
        runRecordStore: any RunRecordStore,
        processor: BatchProcessor
    ) -> RunOrchestrator {
        let runtime = makeRunRuntime()
        let synchronizePreview: (@Sendable (
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> SyncResult)? = if let runtime {
            { scope, configuration in
                let syncService = try await runtime.makeSync(
                    configuration: configuration,
                    scope: scope
                )
                return try await syncService.synchronizeNow()
            }
        } else {
            nil
        }
        let write = writeDependencies(
            store: runRecordStore,
            processor: processor,
            writeFixPlan: makeWriteRunner(runtime: runtime)
        )

        return RunOrchestrator(dependencies: RunOrchestrator.Dependencies(
            synchronizeLibrary: { [syncService] in
                try await syncService.synchronizeNow()
            },
            synchronizePreview: synchronizePreview,
            persistRunRecord: RunRecordSink.make(
                store: runRecordStore,
                // nil after container teardown: the sink skips pruning rather
                // than deleting against a guessed default limit.
                historyLimit: { [weak self] in await self?.runHistoryLimit() },
                pruneFixPlans: { [weak self] in
                    await self?.pruneFixPlans(runRecordStore: runRecordStore)
                }
            ),
            produceFixPlan: makePreviewProducer(runtime: runtime),
            releasePreview: { configuration in
                await runtime?.discard(configuration)
            },
            write: write,
            runBatchUpdate: makeBatchRunnerBridge(),
            currentDecisionTarget: makeCurrentDecisionTarget()
        ))
    }

    /// Bridges the orchestrator's Sendable runner slot onto the live
    /// view-model (D3): the batch executes against the window that
    /// submitted it, so a missing provider fails the run fast instead of
    /// mutating the library without a progress surface.
    func makeBatchRunnerBridge() -> @Sendable (BatchRunInput, RunID) async throws -> BatchUpdateResult {
        { [weak self] input, runID in
            guard let self, let runner = await batchRunProvider else {
                throw AppDependencyServiceError.batchRunnerUnavailable
            }
            return try await runner(input, runID)
        }
    }

    func submitBatchRun(input: BatchRunInput) async throws -> RunSubmissionResult {
        guard let runOrchestrator else {
            throw AppDependencyServiceError.runOrchestratorUnavailable
        }
        return await runOrchestrator.submit(.manualBatchUpdate(
            input: input,
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: input.trackCount
        ))
    }
}
