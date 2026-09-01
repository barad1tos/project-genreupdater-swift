import Core
import Foundation
import OSLog

public actor RunOrchestrator {
    static let lifecycleBufferLimit = 16

    let dependencies: Dependencies
    let log = Logger(subsystem: "com.genreupdater", category: "RunOrchestrator")
    var activeRun: RunLifecycleSnapshot?
    var latestRun: RunLifecycleSnapshot?
    var recoveryState = RecoveryState.clear
    /// The one write request retained while a recovery hold blocks writes.
    /// Managed exclusively by the QueuedWrite extension.
    var queuedWrite: RunRequest?
    /// A queued write released from its slot but not yet parked or started.
    /// Its visibility prevents plan retention from treating it as orphaned.
    /// Defensive, not load-bearing: `submit` registers the request synchronously
    /// before suspension, and this marker is not reentrancy-safe; coverage must
    /// keep resting on slot/pending/activeRun.
    var releasingWrite: RunRequest?
    private var activeTransitions: [RunLifecycleTransition] = []
    /// Internal for the QueuedWrite extension's in-flight visibility only;
    /// mutation stays in this file.
    var pendingTriggers: [PendingTrigger] = []
    private var subscribers: [UUID: LifecycleUpdateBuffer]

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        subscribers = [:]
    }

    public func currentLifecycle() -> RunLifecycleSnapshot? {
        activeRun ?? recoveryState.current?.run?.snapshot ?? latestRun
    }

    public func activeLifecycle() -> RunLifecycleSnapshot? {
        activeRun
    }

    public func lifecycleUpdates() -> LifecycleUpdates {
        let subscriptionID = UUID()
        let buffer = LifecycleUpdateBuffer(limit: Self.lifecycleBufferLimit) { [weak self] in
            Task {
                await self?.removeSubscriber(id: subscriptionID)
            }
        }

        if let lifecycle = currentLifecycle() {
            buffer.push(lifecycle)
        }
        subscribers[subscriptionID] = buffer

        return LifecycleUpdates(buffer: buffer)
    }

    func lifecycleSubscriberCount() -> Int {
        subscribers.count
    }

    public func submit(_ request: RunRequest) async -> RunSubmissionResult {
        if request.intent == .writeFixes, recoveryState.hasWriteBlock {
            // The response shape stays as shipped; retention is additive so
            // existing consumers keep their recovery routing untouched.
            retainWriteBehindRecovery(request)
            if let run = recoveryState.current?.run {
                return .recoverable(run.snapshot, reason: run.reason)
            }
            return .recoveryRequired
        }
        if let activeRun {
            switch TriggerArbiter.decide(active: activeRun, pending: pendingTriggers, incoming: request) {
            case let .alreadyCovered(pending):
                await replacePending(with: pending)
                await releaseCoveredPreview(request, active: activeRun, pending: pending)
                return .alreadyCovered(activeRun: activeRun)
            case let .queue(pending):
                await replacePending(with: pending)
                return .queued(activeRun: activeRun)
            }
        }

        let runTask = startRun(for: request, startedAt: dependencies.now())
        return await runTask.value
    }

    private func startRun(
        for request: RunRequest,
        startedAt: Date
    ) -> Task<RunSubmissionResult, Never> {
        // No suspension between the activeRun check and publish(created):
        // single-flight stays airtight without extra locking.
        let created = RunLifecycleSnapshot.created(
            for: request, at: startedAt, hasRecoveryHold: recoveryState.hasWriteBlock
        )
        activeTransitions = []
        advance(created, at: startedAt)
        let running = created.beginning(for: request.intent)
        advance(running)

        // The run executes in an orchestrator-owned task: awaiting the value of
        // an unstructured Task's value never forwards the submitter's
        // cancellation into the run.
        return Task { await executeRun(from: running, request: request) }
    }

    private func executeRun(
        from lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) async -> RunSubmissionResult {
        if let failure = await recordPreflight(lifecycle, request: request) {
            return failure
        }

        do {
            return try await finishRunWork(from: lifecycle, request: request)
        } catch is CancellationError {
            await releasePreview(request)
            log.error("Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) cancelled")
            let current = activeRun ?? lifecycle
            if request.intent == .writeFixes, current.hasWriteUncertainty {
                return await finishRecoverableRun(
                    from: current,
                    failureMessage: "Write cancelled with an uncertain outcome; verify Music.app before continuing"
                )
            }
            return await finishCancelledRun(from: current, message: "Run cancelled")
        } catch let WorkCheckpointError.store(failure) where request.intent == .writeFixes {
            return await finishCheckpointFailure(failure, request: request)
        } catch let error as WorkCheckpointError where request.intent == .writeFixes && error.needsRecovery {
            await releasePreview(request)
            return await finishRecoverableRun(
                from: activeRun ?? lifecycle,
                failureMessage: error.localizedDescription
            )
        } catch let error as AppleScriptOutcomeError where request.intent.isMutating {
            await releasePreview(request)
            log.error("""
            Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) requires recovery after \
            \(error.localizedDescription, privacy: .private)
            """)
            return await finishRecoverableRun(
                from: activeRun ?? lifecycle,
                failureMessage: error.localizedDescription
            )
        } catch {
            let current = activeRun ?? lifecycle
            await releasePreview(request)
            // Error descriptions stay private: sync/write errors can embed track or artist names.
            log.error("""
            Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) failed with \
            \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            if request.intent == .writeFixes, current.hasWriteUncertainty || Self.isFinalizationFailure(error) {
                return await finishRecoverableRun(
                    from: current,
                    failureMessage: error.localizedDescription
                )
            }
            return await finishFailedRun(from: current, failureMessage: error.localizedDescription)
        }
    }

    private func finishCheckpointFailure(
        _ failure: CheckpointStoreFailure,
        request: RunRequest
    ) async -> RunSubmissionResult {
        await releasePreview(request)
        return await finishFailedRun(
            from: failure.candidate,
            failureMessage: failure.localizedDescription,
            checkpoint: failure.checkpoint,
            durableFallback: failure.durableSnapshot
        )
    }

    func finishSuccessfulRun(
        _ work: RunWork,
        intent: RunIntent,
        chainedRequest: RunRequest? = nil
    ) async -> RunSubmissionResult {
        let reporting = beginReporting(from: work.reportingSource)
        let finishedAt = auditTime()
        let completed = reporting.finishing(
            result: work.result,
            hasActionableWork: work.hasActionableWork,
            at: finishedAt
        )
        appendTransition(completed.state, at: finishedAt)
        let isStored = await persistRecord(
            for: completed,
            syncResult: completed.syncResult,
            writeSummary: work.writeSummary,
            failureMessage: nil,
            finishedAt: completed.finishedAt
        )
        if !isStored {
            activeTransitions.removeLast()
            if reporting.hasWriteProgress || (work.writeSummary?.applied ?? 0) > 0 {
                return await finishUnstoredWrite(
                    from: reporting,
                    syncResult: completed.syncResult,
                    writeSummary: work.writeSummary,
                    failureMessage: nil
                )
            }
            return await finishFailedRun(
                from: reporting,
                failureMessage: intent.isMutating
                    ? "Verified write run could not persist its terminal record"
                    : "Fix plan result could not persist its terminal record",
                syncResult: completed.syncResult,
                writeSummary: work.writeSummary,
                isTerminalRetry: true
            )
        }
        if intent == .writeFixes {
            await dependencies.recordSuccessfulProcessing?()
        }
        await publishInactive(completed)
        if let chainedRequest, recoveryState.hasWriteBlock == false {
            let outrankingRequests = pendingTriggers.filter {
                TriggerArbiter.outranks($0.request, chainedRequest)
            }
            if outrankingRequests.contains(where: \.request.canWriteLibrary) {
                startPendingRun()
                return .completed(completed)
            }
            if !outrankingRequests.isEmpty {
                pendingTriggers.append(PendingTrigger(request: chainedRequest))
                startPendingRun()
                return .queued(activeRun: activeRun ?? completed)
            }
            let chainedTask = startRun(for: chainedRequest, startedAt: dependencies.now())
            return await chainedTask.value
        }
        startPendingRun()
        if case .finished(.completedNoOp, _) = completed.phase {
            return .completedNoOp(completed)
        }
        return .completed(completed)
    }

    private func recordPreflight(
        _ lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) async -> RunSubmissionResult? {
        // A crash mid-run leaves this open record as interrupted-run evidence.
        let isStored = await persistRecord(
            for: lifecycle,
            syncResult: nil,
            writeSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )
        guard request.intent.isMutating, !isStored else { return nil }
        await releasePreview(request)
        return await finishFailedRun(
            from: lifecycle,
            failureMessage: "Write run could not start because run history is unavailable"
        )
    }

    private func releaseCoveredPreview(
        _ request: RunRequest,
        active: RunLifecycleSnapshot,
        pending: [PendingTrigger]
    ) async {
        guard let configurationID = request.previewConfiguration?.id else { return }
        let isActive = active.previewConfiguration?.id == configurationID
        let isPending = pending.contains { $0.request.previewConfiguration?.id == configurationID }
        guard !isActive, !isPending else { return }
        await releasePreview(request)
    }

    private func replacePending(with replacement: [PendingTrigger]) async {
        let retainedConfigurationIDs = Set(replacement.compactMap { $0.request.previewConfiguration?.id })
        let removed = pendingTriggers.filter { pending in
            guard let configurationID = pending.request.previewConfiguration?.id else { return false }
            return !retainedConfigurationIDs.contains(configurationID)
        }
        pendingTriggers = replacement
        for pending in removed {
            await releasePreview(pending.request)
        }
    }

    func performRunWork(
        from lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) async throws -> RunWork {
        switch request.kind {
        case .observeLibrary:
            let syncResult = try await dependencies.synchronizeLibrary(lifecycle.scope)
            let committed = try await persistCommittedScope(from: lifecycle, syncResult: syncResult)
            return RunWork(
                reportingSource: committed,
                result: syncResult,
                hasActionableWork: syncResult.hasChanges,
                writeSummary: nil,
                failureMessage: nil
            )
        case let .previewFixes(configuration):
            let syncResult: SyncResult
            if let synchronizePreview = dependencies.synchronizePreview {
                let refreshPolicy: MetadataRefreshPolicy = request.trigger.usesAuthoritativeInputs
                    ? .force
                    : .fast
                syncResult = try await synchronizePreview(lifecycle.scope, configuration, refreshPolicy)
            } else {
                syncResult = try await dependencies.synchronizeLibrary(lifecycle.scope)
            }
            let committed = try await persistCommittedScope(from: lifecycle, syncResult: syncResult)
            guard let produceFixPlan = dependencies.produceFixPlan else {
                throw RunWorkError.missingFixPlanProducer
            }
            let planning = beginFixPlanning(from: committed)
            let production = try await produceFixPlan(planning.runID, planning.scope, configuration)
            return RunWork(
                reportingSource: planning,
                result: syncResult,
                hasActionableWork: production.producedPlan,
                writeSummary: nil,
                failureMessage: nil,
                producedPlanID: production.planID
            )
        case let .writeFixes(writeInput):
            return try await performWrite(writeInput, from: lifecycle)
        case let .batchUpdate(input):
            return try await performBatch(input, from: lifecycle)
        }
    }

    private func persistCommittedScope(
        from lifecycle: RunLifecycleSnapshot,
        syncResult: SyncResult
    ) async throws -> RunLifecycleSnapshot {
        let committed = try lifecycle.usingCommittedScope(syncResult.scope)
        let isStored = await persistRecord(
            for: committed,
            syncResult: nil,
            writeSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )
        guard isStored else {
            throw RunWorkError.committedScopePersistence
        }
        publish(committed)
        return committed
    }

    private func performWrite(
        _ input: FixPlanWriteInput,
        from lifecycle: RunLifecycleSnapshot
    ) async throws -> RunWork {
        guard let writeFixPlan = dependencies.write?.writeFixPlan else {
            throw RunWorkError.missingWriteRunner
        }
        let result = try await writeFixPlan(input, lifecycle.runID) { [weak self] checkpoint in
            guard let self else {
                throw WorkCheckpointError.persistence(
                    checkpoint.boundary,
                    writeAdjacent: checkpoint.boundary != .beforeAttempt
                )
            }
            try await self.apply(checkpoint)
        }
        let checkpointed = activeRun ?? lifecycle
        guard !checkpointed.hasOpenItems else {
            throw WorkCheckpointError.invalid(
                .afterVerification,
                writeAdjacent: checkpointed.hasWriteUncertainty || result.appliedOperationCount > 0,
                reason: "write runner returned with unfinished work items"
            )
        }
        let failureMessage: String? = if result.failedOperationCount > 0 {
            RunWorkError.writeFailure(
                failedOperationCount: result.failedOperationCount,
                failedTrackCount: result.failedTrackCount,
                reasons: result.errorDescriptions,
                isPartial: result.hasPartialFailures
            ).localizedDescription
        } else {
            nil
        }
        return RunWork(
            reportingSource: beginVerifying(from: checkpointed),
            result: Self.makeWriteSyncResult(from: result),
            hasActionableWork: result.appliedOperationCount > 0,
            writeSummary: RunWriteSummary(
                applied: result.appliedOperationCount,
                verifiedNoOp: result.noOpEntries.count,
                failed: result.failedOperationCount
            ),
            failureMessage: failureMessage
        )
    }

    func finishFailedRun(
        from lifecycle: RunLifecycleSnapshot,
        failureMessage: String,
        syncResult: SyncResult? = nil,
        writeSummary: RunWriteSummary? = nil,
        checkpoint: WorkCheckpoint? = nil,
        durableFallback: RunLifecycleSnapshot? = nil,
        isTerminalRetry: Bool = false
    ) async -> RunSubmissionResult {
        let source: RunLifecycleSnapshot
        do {
            let beforeAttempt = checkpoint?.boundary == .beforeAttempt ? checkpoint : nil
            source = try lifecycle.failingUndispatchedWork(beforeAttempt)
        } catch {
            logClosureFailure(error, runID: lifecycle.runID)
            return await finishUnstoredWrite(
                from: lifecycle,
                syncResult: syncResult,
                writeSummary: writeSummary,
                failureMessage: failureMessage,
                durableFallback: durableFallback
            )
        }
        guard !source.hasOpenItems else {
            return await finishUnstoredWrite(
                from: source,
                syncResult: syncResult,
                writeSummary: writeSummary,
                failureMessage: failureMessage,
                durableFallback: durableFallback
            )
        }

        let reporting = prepareFailedReporting(from: source, original: lifecycle, checkpoint: checkpoint)
        let finishedAt = auditTime()
        let failed = reporting.failing(message: failureMessage, at: finishedAt)
        appendTransition(failed.state, at: finishedAt)
        let isStored = await persistRecord(
            for: failed,
            syncResult: syncResult,
            writeSummary: writeSummary,
            failureMessage: failed.failureMessage,
            finishedAt: failed.finishedAt
        )
        let hasWriteEffects = (writeSummary?.applied ?? 0) > 0 || source.hasWriteProgress
        if source.intent.isMutating, !isStored, !isTerminalRetry, !hasWriteEffects {
            activeTransitions.removeLast()
            return await finishFailedRun(
                from: reporting,
                failureMessage: failureMessage,
                syncResult: syncResult,
                writeSummary: writeSummary,
                durableFallback: durableFallback,
                isTerminalRetry: true
            )
        }
        if source.intent.isMutating, !isStored {
            activeTransitions.removeLast()
            return await finishUnstoredWrite(
                from: reporting,
                syncResult: syncResult,
                writeSummary: writeSummary,
                failureMessage: failureMessage,
                durableFallback: durableFallback
            )
        }
        await publishInactive(failed)
        startPendingRun()
        return .failed(failed)
    }

    private func logClosureFailure(_ error: Error, runID: RunID) {
        log.error("""
        Run \(runID.rawValue.uuidString, privacy: .public) failed to close undispatched work with \
        \(String(describing: type(of: error)), privacy: .public): \
        \(error.localizedDescription, privacy: .private)
        """)
    }

    private func prepareFailedReporting(
        from source: RunLifecycleSnapshot,
        original: RunLifecycleSnapshot,
        checkpoint: WorkCheckpoint?
    ) -> RunLifecycleSnapshot {
        if source.state == .reporting {
            return source
        }
        if checkpoint != nil || source != original {
            let reporting = source.beginningReporting()
            appendTransition(reporting.state)
            return reporting
        }
        return beginReporting(from: source)
    }

    private func finishRecoverableRun(
        from lifecycle: RunLifecycleSnapshot,
        failureMessage: String
    ) async -> RunSubmissionResult {
        let recoverable = lifecycle.requiringRecovery()
        appendTransition(recoverable.state)
        let recoveryID = await dependencies.write?.beginRecoveryHold?()
        await persistRecord(
            for: recoverable,
            syncResult: nil,
            writeSummary: nil,
            recoveryID: recoveryID,
            failureMessage: failureMessage,
            finishedAt: nil
        )
        installLiveRecovery(RecoveryRun(
            snapshot: recoverable,
            reason: failureMessage,
            holdID: recoveryID ?? recoverable.runID.rawValue
        ))
        discardPendingWrites()
        await publishInactive(recoverable)
        startPendingRun()
        return .recoverable(recoverable, reason: failureMessage)
    }

    private func finishUnstoredWrite(
        from reporting: RunLifecycleSnapshot,
        syncResult: SyncResult?,
        writeSummary: RunWriteSummary?,
        failureMessage: String?,
        durableFallback: RunLifecycleSnapshot? = nil
    ) async -> RunSubmissionResult {
        let message = unstoredWriteMessage(for: reporting, failureMessage: failureMessage)
        let recoverable = reporting.requiringRecovery()
        appendTransition(recoverable.state)
        let recoveryID = await dependencies.write?.beginRecoveryHold?()
        let isStored = await persistRecord(
            for: recoverable,
            syncResult: syncResult,
            writeSummary: writeSummary,
            recoveryID: recoveryID,
            failureMessage: message,
            finishedAt: nil
        )
        let heldSnapshot: RunLifecycleSnapshot
        let heldMessage: String
        if !isStored, let durableFallback {
            heldSnapshot = durableFallback.requiringRecovery()
            heldMessage = unstoredWriteMessage(for: durableFallback, failureMessage: failureMessage)
        } else {
            heldSnapshot = recoverable
            heldMessage = message
        }
        installLiveRecovery(RecoveryRun(
            snapshot: heldSnapshot,
            reason: heldMessage,
            holdID: recoveryID ?? heldSnapshot.runID.rawValue
        ))
        discardPendingWrites()
        await publishInactive(heldSnapshot)
        startPendingRun()
        return .recoverable(heldSnapshot, reason: heldMessage)
    }

    private func unstoredWriteMessage(
        for lifecycle: RunLifecycleSnapshot,
        failureMessage: String?
    ) -> String {
        let finalizationMessage = lifecycle.hasWriteUncertainty
            ? "Run history could not be finalized after a write attempt. Verify Music.app before continuing."
            : "Run history could not be finalized. Writes remain blocked until history is available."
        return failureMessage.map { "\($0): \(finalizationMessage)" } ?? finalizationMessage
    }

    private func finishCancelledRun(
        from lifecycle: RunLifecycleSnapshot,
        message: String
    ) async -> RunSubmissionResult {
        let reporting = beginReporting(from: lifecycle)
        let finishedAt = auditTime()
        // Cancellation reaches here only without write uncertainty. Close prepared work as
        // `.skipped` while retaining the pre-close checkpoint for unstored-terminal recovery.
        let closed: RunLifecycleSnapshot
        do {
            closed = try reporting.skippingOpenWork()
        } catch {
            log.error("""
            Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) could not close open work \
            on cancellation: \(error.localizedDescription, privacy: .private)
            """)
            return await finishUnstoredWrite(
                from: reporting,
                syncResult: nil,
                writeSummary: nil,
                failureMessage: message
            )
        }
        let cancelled = closed.cancelling(message: message, at: finishedAt)
        appendTransition(cancelled.state, at: finishedAt)
        let isStored = await persistRecord(
            for: cancelled,
            syncResult: nil,
            writeSummary: nil,
            failureMessage: cancelled.failureMessage,
            finishedAt: cancelled.finishedAt
        )
        if lifecycle.intent.isMutating, !isStored {
            activeTransitions.removeLast()
            if lifecycle.hasWriteProgress {
                return await finishUnstoredWrite(
                    from: closed,
                    syncResult: nil,
                    writeSummary: nil,
                    failureMessage: message
                )
            }
            // Never publish a cancelled terminal whose record did not persist.
            return await finishFailedRun(
                from: closed,
                failureMessage: "\(message); run history could not be finalized",
                isTerminalRetry: true
            )
        }
        await publishInactive(cancelled)
        startPendingRun()
        return .cancelled(cancelled)
    }

    private func startPendingRun() {
        if recoveryState.hasWriteBlock {
            discardPendingWrites()
        }
        guard !pendingTriggers.isEmpty else { return }
        let pending = pendingTriggers.removeFirst()
        _ = startRun(for: pending.request, startedAt: dependencies.now())
    }

    func discardPendingWrites() {
        // Queue acknowledgements are not completion handles; recovery cancels pending mutating runs fail-closed.
        pendingTriggers.removeAll { $0.request.intent.isMutating }
    }

    /// A user cancel must reach a batch that has not started yet: purging
    /// the pending trigger means no stale trigger can later fire into a
    /// foreign stash or fake arbiter coverage.
    public func discardPendingBatchRuns() {
        pendingTriggers.removeAll { $0.request.intent == .batchUpdate }
    }

    private func beginFixPlanning(from lifecycle: RunLifecycleSnapshot) -> RunLifecycleSnapshot {
        let planning = lifecycle.beginningFixPlanning()
        advance(planning)
        return planning
    }

    private func beginVerifying(from lifecycle: RunLifecycleSnapshot) -> RunLifecycleSnapshot {
        let verifying = lifecycle.beginningVerifying()
        advance(verifying)
        return verifying
    }

    private func beginReporting(from lifecycle: RunLifecycleSnapshot) -> RunLifecycleSnapshot {
        let reporting = lifecycle.beginningReporting()
        advance(reporting)
        return reporting
    }

    private func apply(_ checkpoint: WorkCheckpoint) async throws {
        guard let activeRun else {
            throw WorkCheckpointError.persistence(
                checkpoint.boundary,
                writeAdjacent: checkpoint.boundary != .beforeAttempt
            )
        }
        if checkpoint.boundary == .beforeAttempt, recoveryState.pending != nil {
            throw RunWorkError.recoveryPending
        }
        let writeAdjacent = activeRun.isWriteAdjacent(to: checkpoint)
        let checkpointed = try activeRun.applying(checkpoint)
        if let reason = await checkpointFailureReason(checkpoint, for: checkpointed) {
            throw WorkCheckpointError.store(CheckpointStoreFailure(
                checkpoint: checkpoint,
                candidate: checkpointed,
                durableSnapshot: activeRun,
                isWriteAdjacent: writeAdjacent,
                reason: reason
            ))
        }
        publish(checkpointed)
    }

    private func checkpointFailureReason(
        _ checkpoint: WorkCheckpoint,
        for lifecycle: RunLifecycleSnapshot
    ) async -> String? {
        guard let persistCheckpoint = dependencies.write?.persistCheckpoint else {
            let record = RunRecord(
                lifecycle: lifecycle,
                transitions: activeTransitions,
                syncSummary: nil,
                failureMessage: nil,
                finishedAt: nil
            )
            return await storeFailure(for: record)
        }
        do {
            try await persistCheckpoint(lifecycle.runID, checkpoint)
            return nil
        } catch {
            log.error("""
            Run checkpoint persistence failed with \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            return error.localizedDescription
        }
    }

    /// Records and publishes ordinary active transitions in one step. Terminalization may stage
    /// a transition with `appendTransition` until its corresponding record is durable.
    private func advance(_ lifecycle: RunLifecycleSnapshot, at timestamp: Date? = nil) {
        appendTransition(lifecycle.state, at: timestamp)
        publish(lifecycle)
    }

    private func appendTransition(_ state: RunLifecycleState, at timestamp: Date? = nil) {
        activeTransitions.append(RunLifecycleTransition(
            state: state,
            timestamp: auditTime(timestamp)
        ))
    }

    private func auditTime(_ timestamp: Date? = nil) -> Date {
        max(timestamp ?? dependencies.now(), activeTransitions.last?.timestamp ?? .distantPast)
    }

    @discardableResult
    private func persistRecord(
        for lifecycle: RunLifecycleSnapshot,
        syncResult: SyncResult?,
        writeSummary: RunWriteSummary?,
        recoveryID: UUID? = nil,
        failureMessage: String?,
        finishedAt: Date?
    ) async -> Bool {
        let record = RunRecord(
            lifecycle: lifecycle,
            transitions: activeTransitions,
            recoveryID: recoveryID,
            syncSummary: syncResult.map(ActivitySyncSummary.init(result:)),
            writeSummary: writeSummary,
            failureMessage: failureMessage,
            finishedAt: finishedAt
        )

        return await storeFailure(for: record) == nil
    }

    private func storeFailure(for record: RunRecord) async -> String? {
        do {
            try await dependencies.persistRunRecord(record)
            return nil
        } catch {
            log.error("""
            Failed to persist run record \(record.runID.rawValue.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            return error.localizedDescription
        }
    }

    private func publish(_ lifecycle: RunLifecycleSnapshot) {
        activeRun = lifecycle
        latestRun = lifecycle
        broadcast(lifecycle)
    }

    private func publishInactive(_ lifecycle: RunLifecycleSnapshot) async {
        latestRun = lifecycle
        broadcast(lifecycle)
        await promotePending()
        activeRun = nil
        guard let run = recoveryState.current?.run,
              run.snapshot.runID != lifecycle.runID
        else { return }
        latestRun = run.snapshot
        broadcast(run.snapshot)
    }

    func broadcast(_ lifecycle: RunLifecycleSnapshot) {
        for subscriber in subscribers.values {
            subscriber.push(lifecycle)
        }
    }

    private func removeSubscriber(id: UUID) {
        subscribers[id] = nil
    }
}
