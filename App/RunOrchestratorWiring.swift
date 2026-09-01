import Core
import Foundation
import Services

enum ProcessingAdmissionAction: String, Sendable {
    case workflowMutation = "Workflow mutation"
    case fixPlanWrite = "Fix-plan write"
}

enum ProcessingAdmissionFailure: LocalizedError {
    case unavailable(ProcessingAdmissionAction)
    case rejected(ProcessingAdmissionAction, ProcessingAdmissionRejection)

    var errorDescription: String? {
        switch self {
        case let .unavailable(action):
            "\(action.rawValue) is unavailable until the library mirror is ready."
        case let .rejected(action, reason):
            "\(action.rawValue) was refused because its library evidence is no longer current (\(reason))."
        }
    }
}

/// Run-orchestrator wiring, split from the main dependencies file: the
/// closures here bridge the actor's Sendable dependency surface onto
/// main-actor services and providers.
extension AppDependencies {
    func makeWorkflowAdmission() -> @Sendable (
        [Track],
        AdmissionTrackMatch
    ) async throws -> ProcessingAdmission {
        { [weak self] tracks, match in
            guard let self else {
                throw ProcessingAdmissionFailure.unavailable(.workflowMutation)
            }
            return try await self.admitProcessing(
                tracks: tracks,
                match: match,
                action: .workflowMutation
            )
        }
    }

    func makeWorkflowValidator() -> @Sendable (
        ProcessingAdmission,
        [Track],
        AdmissionTrackMatch
    ) async throws -> Void {
        { [weak self] admission, tracks, match in
            guard let self else {
                throw ProcessingAdmissionFailure.unavailable(.workflowMutation)
            }
            try await self.validateProcessing(
                admission,
                tracks: tracks,
                match: match,
                action: .workflowMutation
            )
        }
    }

    func admitProcessing(
        tracks: [Track],
        match: AdmissionTrackMatch,
        action: ProcessingAdmissionAction
    ) async throws -> ProcessingAdmission {
        guard let trackStore else {
            throw ProcessingAdmissionFailure.unavailable(action)
        }
        let runtimeConfiguration = try LibrarySyncRuntimeConfiguration(configuration: config)
        let requirement = runtimeConfiguration.processingRequirement
        let now = Date()
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: requirement.normalizedTestArtists,
            knownTrackCount: tracks.count,
            createdAt: now,
            reason: action.rawValue
        )
        let decision = try await trackStore.admit(scope: scope, requirement: requirement, at: now)
        let admission: ProcessingAdmission
        switch decision {
        case let .admitted(captured, _):
            admission = captured
        case let .rejected(reason):
            throw ProcessingAdmissionFailure.rejected(action, reason)
        }
        try await validateProcessing(admission, tracks: tracks, match: match, action: action)
        return admission
    }

    func validateProcessing(
        _ admission: ProcessingAdmission,
        tracks: [Track],
        match: AdmissionTrackMatch,
        action: ProcessingAdmissionAction
    ) async throws {
        guard let trackStore else {
            throw ProcessingAdmissionFailure.unavailable(action)
        }
        let decision = try await trackStore.revalidate(
            admission,
            candidates: tracks,
            match: match,
            at: Date()
        )
        if case let .rejected(reason) = decision {
            throw ProcessingAdmissionFailure.rejected(action, reason)
        }
    }

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
        processor: BatchProcessor,
        runtimeFactory: RunRuntimeFactory? = nil
    ) -> RunOrchestrator {
        let runtime = runtimeFactory ?? makeRunRuntime()
        let synchronizePreview: (@Sendable (
            ProcessingScopeSnapshot,
            FixPlanConfig,
            MetadataRefreshPolicy
        ) async throws -> SyncResult)? = if let runtime {
            { scope, configuration, refreshPolicy in
                let syncService = try await runtime.makeSync(
                    configuration: configuration,
                    scope: scope
                )
                return try await syncService.synchronizeNow(forceMetadataRefresh: refreshPolicy == .force)
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
            synchronizeLibrary: { [syncService] scope in
                try await syncService.synchronizeNow(capturedScope: scope)
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
            prepareAutomaticWrite: makeAutomaticWriteBuilder(),
            releasePreview: { configuration in
                await runtime?.discard(configuration)
            },
            write: write,
            runBatchUpdate: makeBatchRunnerBridge(),
            currentDecisionTarget: makeCurrentDecisionTarget(),
            recordSuccessfulProcessing: { [weak self] in
                guard let self else { return }
                await self.incrementalRunTracker?.updateLastRunTimestamp()
                await self.refreshIncrementalRunTimestamp()
            }
        ))
    }

    func makeAutomaticWriteBuilder() -> @Sendable (
        FixPlanID,
        RunConfig,
        RunTrigger
    ) async throws -> FixPlanWriteInput {
        { [weak self] planID, planning, trigger in
            guard let self else {
                throw AppDependencyServiceError.runOrchestratorUnavailable
            }
            guard let store = await self.fixPlanStore else {
                throw AppDependencyServiceError.fixPlanStoreUnavailable
            }
            guard let gate = await self.featureGate else {
                throw AppDependencyServiceError.featureGateUnavailable
            }
            if trigger == .backgroundSync || trigger == .fileSystemEvent {
                try await gate.require(.autoSync)
            }
            guard let decision = try await store.currentDecision(for: planID) else {
                throw FixPlanWrite.Failure.missingDecision(planID)
            }
            guard let plan = try await store.plan(id: planID, revision: decision.planRevision) else {
                throw FixPlanWrite.Failure.missingPlan(planID)
            }
            let configuration = RunConfig(
                capturedAt: Date(),
                mode: planning.mode,
                writeAuthority: .automaticPlan,
                automation: planning.automation,
                scopeID: plan.scope.id,
                settings: plan.configuration,
                hadRecoveryHold: false
            )
            return try FixPlanWrite.makeInput(
                plan: plan,
                decision: decision,
                configuration: configuration
            )
        }
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
