import Core
import Foundation
import OSLog

public actor RunOrchestrator {
    static let lifecycleBufferLimit = 16

    public struct WriteDependencies: Sendable {
        public let persistCheckpoint: (@Sendable (RunID, WorkCheckpoint) async throws -> Void)?
        public let writeFixPlan: @Sendable (
            FixPlanWriteInput,
            @escaping WorkCheckpointSink
        ) async throws -> BatchUpdateResult
        public let beginRecoveryHold: (@Sendable () async -> UUID)?

        public init(
            persistCheckpoint: (@Sendable (RunID, WorkCheckpoint) async throws -> Void)? = nil,
            writeFixPlan: @escaping @Sendable (
                FixPlanWriteInput,
                @escaping WorkCheckpointSink
            ) async throws -> BatchUpdateResult,
            beginRecoveryHold: (@Sendable () async -> UUID)? = nil
        ) {
            self.persistCheckpoint = persistCheckpoint
            self.writeFixPlan = writeFixPlan
            self.beginRecoveryHold = beginRecoveryHold
        }
    }

    public struct Dependencies: Sendable {
        public let synchronizeLibrary: @Sendable () async throws -> SyncResult
        public let synchronizePreview: (@Sendable (
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> SyncResult)?
        public let persistRunRecord: @Sendable (RunRecord) async throws -> Void
        public let produceFixPlan: (@Sendable (
            RunID,
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> FixPlanProduction)?
        public let releasePreview: (@Sendable (FixPlanConfig) async -> Void)?
        public let write: WriteDependencies?
        public let now: @Sendable () -> Date

        public init(
            synchronizeLibrary: @escaping @Sendable () async throws -> SyncResult,
            synchronizePreview: (@Sendable (
                ProcessingScopeSnapshot,
                FixPlanConfig
            ) async throws -> SyncResult)? = nil,
            persistRunRecord: @escaping @Sendable (RunRecord) async throws -> Void,
            produceFixPlan: (@Sendable (
                RunID,
                ProcessingScopeSnapshot,
                FixPlanConfig
            ) async throws -> FixPlanProduction)? = nil,
            releasePreview: (@Sendable (FixPlanConfig) async -> Void)? = nil,
            write: WriteDependencies? = nil,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.synchronizeLibrary = synchronizeLibrary
            self.synchronizePreview = synchronizePreview
            self.persistRunRecord = persistRunRecord
            self.produceFixPlan = produceFixPlan
            self.releasePreview = releasePreview
            self.write = write
            self.now = now
        }
    }

    private enum RunWorkError: LocalizedError {
        case missingFixPlanProducer
        case missingWriteRunner
        case writeFailure(
            failedOperationCount: Int,
            failedTrackCount: Int,
            reasons: [String],
            isPartial: Bool
        )

        var errorDescription: String? {
            switch self {
            case .missingFixPlanProducer:
                "Fix plan producer is unavailable"
            case .missingWriteRunner:
                "Fix plan write runner is unavailable"
            case let .writeFailure(failedOperationCount, failedTrackCount, reasons, isPartial):
                Self.writeFailureDescription(
                    failedOperationCount: failedOperationCount,
                    failedTrackCount: failedTrackCount,
                    reasons: reasons,
                    isPartial: isPartial
                )
            }
        }

        private static func writeFailureDescription(
            failedOperationCount: Int,
            failedTrackCount: Int,
            reasons: [String],
            isPartial: Bool
        ) -> String {
            let failureKind = isPartial ? "partially failed" : "failed"
            let summary = "Write run \(failureKind): \(failedOperationCount) operations failed across " +
                "\(failedTrackCount) tracks"
            let details = reasons.filter { !$0.isEmpty }.joined(separator: "; ")
            return details.isEmpty ? summary : "\(summary). Errors: \(details)"
        }
    }

    private struct RunWork {
        let reportingSource: RunLifecycleSnapshot
        let result: SyncResult
        let hasActionableWork: Bool
        let writeSummary: RunWriteSummary?
        let failureMessage: String?
    }

    private struct RecoveryRun {
        let snapshot: RunLifecycleSnapshot
        let reason: String
    }

    private let dependencies: Dependencies
    private let log = Logger(subsystem: "com.genreupdater", category: "RunOrchestrator")
    private var activeRun: RunLifecycleSnapshot?
    private var latestRun: RunLifecycleSnapshot?
    private var recoveryRun: RecoveryRun?
    private var activeTransitions: [RunLifecycleTransition] = []
    private var pendingTriggers: [PendingTrigger] = []
    private var subscribers: [UUID: LifecycleUpdateBuffer]

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        subscribers = [:]
    }

    public func currentLifecycle() -> RunLifecycleSnapshot? {
        activeRun ?? recoveryRun?.snapshot ?? latestRun
    }

    public func activeLifecycle() -> RunLifecycleSnapshot? {
        activeRun
    }

    public func restoreRecovery(_ record: RunRecord) async {
        guard record.intent == .writeFixes,
              record.finishedAt == nil,
              record.state.needsWriteRecovery
        else { return }
        let snapshot = RunLifecycleSnapshot(recovering: record)
        let reason = record.failureMessage ?? "Interrupted write requires Music.app verification."
        recoveryRun = RecoveryRun(snapshot: snapshot, reason: reason)
        discardPendingWrites()
        if activeRun == nil {
            latestRun = snapshot
            broadcast(snapshot)
        }
    }

    /// Resolves only recoverable holds; blocked records require a separate repair path.
    public func resolveRecovery(runID: RunID, at finishedAt: Date) {
        guard let recoveryRun, recoveryRun.snapshot.runID == runID else { return }
        guard case .suspended(.recoverable) = recoveryRun.snapshot.phase else { return }
        let recovering = recoveryRun.snapshot.beginningRecovery()
        let resolved = recovering.cancelling(
            message: "Recovery closed after Music.app verification.",
            at: finishedAt
        )
        self.recoveryRun = nil
        if activeRun == nil {
            latestRun = resolved
            broadcast(resolved)
        }
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
        if request.intent == .writeFixes, let recoveryRun {
            return .recoverable(recoveryRun.snapshot, reason: recoveryRun.reason)
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
        let created = makeCreatedLifecycle(for: request, startedAt: startedAt)
        activeTransitions = []
        advance(created, at: startedAt)
        let running = beginRun(created, request: request)
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
            let work = try await performRunWork(from: lifecycle, request: request)
            await releasePreview(request)
            if let failureMessage = work.failureMessage {
                return await finishFailedRun(
                    from: work.reportingSource,
                    failureMessage: failureMessage,
                    syncResult: work.result,
                    writeSummary: work.writeSummary
                )
            }
            return await finishSuccessfulRun(work, intent: request.intent)
        } catch is CancellationError {
            await releasePreview(request)
            log.error("Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) cancelled")
            let current = activeRun ?? lifecycle
            if request.intent == .writeFixes, current.hasDispatchedWrite {
                return await finishRecoverableRun(
                    from: current,
                    failureMessage: "Write cancelled after durable progress; verify Music.app before continuing"
                )
            }
            return await finishCancelledRun(from: current, message: "Run cancelled")
        } catch let error as WorkCheckpointError where request.intent == .writeFixes && error.needsRecovery {
            await releasePreview(request)
            return await finishRecoverableRun(
                from: activeRun ?? lifecycle,
                failureMessage: error.localizedDescription
            )
        } catch let error as AppleScriptOutcomeError where request.intent == .writeFixes {
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
            if request.intent == .writeFixes, current.hasWriteUncertainty {
                return await finishRecoverableRun(
                    from: current,
                    failureMessage: error.localizedDescription
                )
            }
            return await finishFailedRun(from: current, failureMessage: error.localizedDescription)
        }
    }

    private func finishSuccessfulRun(_ work: RunWork, intent: RunIntent) async -> RunSubmissionResult {
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
        if intent == .writeFixes, !isStored {
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
                failureMessage: "Verified write run could not persist its terminal record",
                syncResult: completed.syncResult,
                writeSummary: work.writeSummary,
                isTerminalRetry: true
            )
        }
        publishInactive(completed)
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
        guard request.intent == .writeFixes, !isStored else { return nil }
        await releasePreview(request)
        return await finishFailedRun(
            from: lifecycle,
            failureMessage: "Write run could not start because run history is unavailable"
        )
    }

    private func releasePreview(_ request: RunRequest) async {
        guard let configuration = request.previewConfiguration,
              let releasePreview = dependencies.releasePreview else { return }
        await releasePreview(configuration)
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

    private func performRunWork(
        from lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) async throws -> RunWork {
        switch request.kind {
        case .observeLibrary:
            let syncResult = try await dependencies.synchronizeLibrary()
            return RunWork(
                reportingSource: lifecycle,
                result: syncResult,
                hasActionableWork: syncResult.hasChanges,
                writeSummary: nil,
                failureMessage: nil
            )
        case let .previewFixes(configuration):
            let syncResult: SyncResult = if let synchronizePreview = dependencies.synchronizePreview {
                try await synchronizePreview(lifecycle.scope, configuration)
            } else {
                try await dependencies.synchronizeLibrary()
            }
            guard let produceFixPlan = dependencies.produceFixPlan else {
                throw RunWorkError.missingFixPlanProducer
            }
            let planning = beginFixPlanning(from: lifecycle)
            let production = try await produceFixPlan(planning.runID, planning.scope, configuration)
            return RunWork(
                reportingSource: planning,
                result: syncResult,
                hasActionableWork: production.producedPlan,
                writeSummary: nil,
                failureMessage: nil
            )
        case let .writeFixes(writeInput):
            return try await performWrite(writeInput, from: lifecycle)
        }
    }

    private func performWrite(
        _ input: FixPlanWriteInput,
        from lifecycle: RunLifecycleSnapshot
    ) async throws -> RunWork {
        guard let writeFixPlan = dependencies.write?.writeFixPlan else {
            throw RunWorkError.missingWriteRunner
        }
        let result = try await writeFixPlan(input) { [weak self] checkpoint in
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

    private static func makeWriteSyncResult(from result: BatchUpdateResult) -> SyncResult {
        SyncResult(modifiedTracks: result.entries.map { entry in
            Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.artist,
                album: entry.albumName
            )
        })
    }

    private func finishFailedRun(
        from lifecycle: RunLifecycleSnapshot,
        failureMessage: String,
        syncResult: SyncResult? = nil,
        writeSummary: RunWriteSummary? = nil,
        isTerminalRetry: Bool = false
    ) async -> RunSubmissionResult {
        let reporting = lifecycle.state == .reporting ? lifecycle : beginReporting(from: lifecycle)
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
        let shouldRecover = isTerminalRetry || (writeSummary?.applied ?? 0) > 0 || lifecycle.hasWriteProgress
        if lifecycle.intent == .writeFixes, !isStored, shouldRecover {
            activeTransitions.removeLast()
            return await finishUnstoredWrite(
                from: reporting,
                syncResult: syncResult,
                writeSummary: writeSummary,
                failureMessage: failureMessage
            )
        }
        publishInactive(failed)
        startPendingRun()
        return .failed(failed)
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
        recoveryRun = RecoveryRun(snapshot: recoverable, reason: failureMessage)
        discardPendingWrites()
        publishInactive(recoverable)
        startPendingRun()
        return .recoverable(recoverable, reason: failureMessage)
    }

    private func finishUnstoredWrite(
        from reporting: RunLifecycleSnapshot,
        syncResult: SyncResult?,
        writeSummary: RunWriteSummary?,
        failureMessage: String?
    ) async -> RunSubmissionResult {
        let hasWriteEffects = reporting.hasWriteProgress || (writeSummary?.applied ?? 0) > 0
        let finalizationMessage = hasWriteEffects
            ? "Write finished, but run history could not be finalized. Verify Music.app before continuing."
            : "Run history could not be finalized. Writes remain blocked until history is available."
        let message = failureMessage.map { "\($0) \(finalizationMessage)" } ?? finalizationMessage
        let recoverable = reporting.requiringRecovery()
        appendTransition(recoverable.state)
        let recoveryID = await dependencies.write?.beginRecoveryHold?()
        await persistRecord(
            for: recoverable,
            syncResult: syncResult,
            writeSummary: writeSummary,
            recoveryID: recoveryID,
            failureMessage: message,
            finishedAt: nil
        )
        recoveryRun = RecoveryRun(snapshot: recoverable, reason: message)
        discardPendingWrites()
        publishInactive(recoverable)
        startPendingRun()
        return .recoverable(recoverable, reason: message)
    }

    private func finishCancelledRun(
        from lifecycle: RunLifecycleSnapshot,
        message: String
    ) async -> RunSubmissionResult {
        let reporting = beginReporting(from: lifecycle)
        let finishedAt = auditTime()
        // Cancellation reaches here before dispatch. Close open work as `.skipped` while retaining
        // the pre-close checkpoint for unstored-terminal recovery.
        let closed: RunLifecycleSnapshot
        do {
            closed = try reporting.skippingOpenWork()
        } catch {
            log.error("""
            Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) could not close open work \
            on cancellation: \(error.localizedDescription, privacy: .public)
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
        if lifecycle.intent == .writeFixes, !isStored {
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
        publishInactive(cancelled)
        startPendingRun()
        return .cancelled(cancelled)
    }

    private func startPendingRun() {
        guard !pendingTriggers.isEmpty else { return }
        let pending = pendingTriggers.removeFirst()
        _ = startRun(for: pending.request, startedAt: dependencies.now())
    }

    private func discardPendingWrites() {
        // Queue acknowledgements are not completion handles; recovery cancels pending writes fail-closed.
        pendingTriggers.removeAll { $0.request.intent == .writeFixes }
    }

    private func beginRun(
        _ lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) -> RunLifecycleSnapshot {
        switch request.kind {
        case .observeLibrary, .previewFixes:
            lifecycle.beginningSync()
        case .writeFixes:
            lifecycle.beginningWriting()
        }
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
        let writeAdjacent = activeRun.isWriteAdjacent(to: checkpoint)
        let checkpointed = try activeRun.applying(checkpoint)
        let isStored = await persist(checkpoint, for: checkpointed)
        guard isStored else {
            throw WorkCheckpointError.persistence(checkpoint.boundary, writeAdjacent: writeAdjacent)
        }
        publish(checkpointed)
    }

    private func persist(_ checkpoint: WorkCheckpoint, for lifecycle: RunLifecycleSnapshot) async -> Bool {
        guard let persistCheckpoint = dependencies.write?.persistCheckpoint else {
            return await persistRecord(
                for: lifecycle,
                syncResult: nil,
                writeSummary: nil,
                failureMessage: nil,
                finishedAt: nil
            )
        }
        do {
            try await persistCheckpoint(lifecycle.runID, checkpoint)
            return true
        } catch {
            log.error(
                "Run checkpoint persistence failed with \(String(describing: type(of: error)), privacy: .public)"
            )
            return false
        }
    }

    /// Records the transition and publishes the snapshot in one step so the
    /// transitions log can never drift from the published lifecycle for
    /// non-terminal (active) transitions.
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

        do {
            try await dependencies.persistRunRecord(record)
            return true
        } catch {
            log.error("""
            Failed to persist run record \(lifecycle.runID.rawValue.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            return false
        }
    }

    private func makeCreatedLifecycle(
        for request: RunRequest,
        startedAt: Date
    ) -> RunLifecycleSnapshot {
        let scope = request.writeInput?.scope ?? ProcessingScopeSnapshot.capture(
            requestedTestArtists: request.requestedTestArtists,
            knownTrackCount: request.knownTrackCount,
            createdAt: startedAt,
            reason: request.trigger.rawValue
        )

        return RunLifecycleSnapshot(
            runID: RunID(),
            request: request,
            scope: scope,
            startedAt: startedAt,
            phase: .active(.created)
        )
    }

    private func publish(_ lifecycle: RunLifecycleSnapshot) {
        activeRun = lifecycle
        latestRun = lifecycle
        broadcast(lifecycle)
    }

    private func publishInactive(_ lifecycle: RunLifecycleSnapshot) {
        activeRun = nil
        latestRun = lifecycle
        broadcast(lifecycle)
        guard let recoveryRun, recoveryRun.snapshot.runID != lifecycle.runID else { return }
        latestRun = recoveryRun.snapshot
        broadcast(recoveryRun.snapshot)
    }

    private func broadcast(_ lifecycle: RunLifecycleSnapshot) {
        for subscriber in subscribers.values {
            subscriber.push(lifecycle)
        }
    }

    private func removeSubscriber(id: UUID) {
        subscribers[id] = nil
    }
}
