import Core
import Foundation
import OSLog

public actor RunOrchestrator {
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
        public let writeFixPlan: (@Sendable (FixPlanWriteTarget) async throws -> BatchUpdateResult)?
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
            writeFixPlan: (@Sendable (FixPlanWriteTarget) async throws -> BatchUpdateResult)? = nil,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.synchronizeLibrary = synchronizeLibrary
            self.synchronizePreview = synchronizePreview
            self.persistRunRecord = persistRunRecord
            self.produceFixPlan = produceFixPlan
            self.releasePreview = releasePreview
            self.writeFixPlan = writeFixPlan
            self.now = now
        }
    }

    private enum RunWorkError: LocalizedError {
        case missingFixPlanProducer
        case missingWriteRunner
        case partialWriteFailure(failedOperationCount: Int, failedTrackCount: Int, reasons: [String])

        var errorDescription: String? {
            switch self {
            case .missingFixPlanProducer:
                "Fix plan producer is unavailable"
            case .missingWriteRunner:
                "Fix plan write runner is unavailable"
            case let .partialWriteFailure(failedOperationCount, failedTrackCount, reasons):
                Self.partialFailureDescription(
                    failedOperationCount: failedOperationCount,
                    failedTrackCount: failedTrackCount,
                    reasons: reasons
                )
            }
        }

        private static func partialFailureDescription(
            failedOperationCount: Int,
            failedTrackCount: Int,
            reasons: [String]
        ) -> String {
            let summary = "Write run partially failed: \(failedOperationCount) operations failed across " +
                "\(failedTrackCount) tracks"
            let details = reasons.filter { !$0.isEmpty }.joined(separator: "; ")
            return details.isEmpty ? summary : "\(summary). Errors: \(details)"
        }
    }

    private struct RunWork {
        let reportingSource: RunLifecycleSnapshot
        let result: SyncResult
        let hasActionableWork: Bool
    }

    private let dependencies: Dependencies
    private let log = Logger(subsystem: "com.genreupdater", category: "RunOrchestrator")
    private var activeRun: RunLifecycleSnapshot?
    private var latestRun: RunLifecycleSnapshot?
    private var activeTransitions: [RunLifecycleTransition] = []
    private var pendingTriggers: [PendingTrigger] = []
    private var continuations: [UUID: AsyncStream<RunLifecycleSnapshot>.Continuation]

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        continuations = [:]
    }

    public func currentLifecycle() -> RunLifecycleSnapshot? {
        activeRun ?? latestRun
    }

    public func lifecycleUpdates() -> AsyncStream<RunLifecycleSnapshot> {
        let subscriptionID = UUID()
        // Terminal snapshots drive UI refreshes; a queued follow-up must not overwrite them for slow subscribers.
        let (stream, continuation) = AsyncStream<RunLifecycleSnapshot>.makeStream(
            bufferingPolicy: .unbounded
        )

        if let lifecycle = currentLifecycle() {
            continuation.yield(lifecycle)
        }
        continuations[subscriptionID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    func lifecycleSubscriptionCountForTesting() -> Int {
        continuations.count
    }

    public func submit(_ request: RunRequest) async -> RunSubmissionResult {
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
        let syncing = created.beginningSync()
        advance(syncing)

        // The run executes in an orchestrator-owned task: awaiting the value of
        // an unstructured Task's value never forwards the submitter's
        // cancellation into the run.
        return Task { await executeRun(from: syncing, request: request) }
    }

    private func executeRun(
        from lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) async -> RunSubmissionResult {
        // Open record: a crash mid-run leaves it with finishedAt == nil as interrupted-run evidence.
        await persistRecord(for: lifecycle, syncResult: nil, failureMessage: nil, finishedAt: nil)

        do {
            let work = try await performRunWork(from: lifecycle, request: request)
            await releasePreview(request)
            let reporting = beginReporting(from: work.reportingSource)
            let completed = reporting.finishing(
                result: work.result,
                hasActionableWork: work.hasActionableWork,
                at: dependencies.now()
            )
            appendTransition(completed.state, at: completed.finishedAt)
            await persistRecord(
                for: completed,
                syncResult: completed.syncResult,
                failureMessage: nil,
                finishedAt: completed.finishedAt
            )
            publishCompleted(completed)
            startPendingRun()
            if case .finished(.completedNoOp, _) = completed.phase {
                return .completedNoOp(completed)
            }
            return .completed(completed)
        } catch is CancellationError {
            await releasePreview(request)
            log.error("Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) cancelled")
            return await finishCancelledRun(from: activeRun ?? lifecycle, message: "Run cancelled")
        } catch {
            await releasePreview(request)
            // Error descriptions stay private: sync/write errors can embed track or artist names.
            log.error("""
            Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) failed with \
            \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            return await finishFailedRun(from: activeRun ?? lifecycle, failureMessage: error.localizedDescription)
        }
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
        let syncResult: SyncResult = if case let .previewFixes(configuration) = request.kind,
                                        let synchronizePreview = dependencies.synchronizePreview {
            try await synchronizePreview(lifecycle.scope, configuration)
        } else {
            try await dependencies.synchronizeLibrary()
        }
        switch request.kind {
        case .observeLibrary:
            return RunWork(
                reportingSource: lifecycle,
                result: syncResult,
                hasActionableWork: syncResult.hasChanges
            )
        case let .previewFixes(configuration):
            guard let produceFixPlan = dependencies.produceFixPlan else {
                throw RunWorkError.missingFixPlanProducer
            }
            let planning = beginFixPlanning(from: lifecycle)
            let production = try await produceFixPlan(planning.runID, planning.scope, configuration)
            return RunWork(
                reportingSource: planning,
                result: syncResult,
                hasActionableWork: production.producedPlan
            )
        case let .writeFixes(writeTarget):
            guard let writeFixPlan = dependencies.writeFixPlan else {
                throw RunWorkError.missingWriteRunner
            }
            let writing = beginWriting(from: lifecycle)
            let writeResult = try await writeFixPlan(writeTarget)
            if writeResult.hasPartialFailures {
                throw RunWorkError.partialWriteFailure(
                    failedOperationCount: writeResult.failedOperationCount,
                    failedTrackCount: writeResult.failedTrackCount,
                    reasons: writeResult.errorDescriptions
                )
            }
            let verifying = beginVerifying(from: writing)
            return RunWork(
                reportingSource: verifying,
                result: Self.makeWriteSyncResult(from: writeResult),
                hasActionableWork: writeResult.appliedOperationCount > 0
            )
        }
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
        failureMessage: String
    ) async -> RunSubmissionResult {
        let reporting = beginReporting(from: lifecycle)
        let failed = reporting.failing(message: failureMessage, at: dependencies.now())
        appendTransition(failed.state, at: failed.finishedAt)
        await persistRecord(
            for: failed,
            syncResult: nil,
            failureMessage: failed.failureMessage,
            finishedAt: failed.finishedAt
        )
        publishCompleted(failed)
        startPendingRun()
        return .failed(failed)
    }

    private func finishCancelledRun(
        from lifecycle: RunLifecycleSnapshot,
        message: String
    ) async -> RunSubmissionResult {
        let reporting = beginReporting(from: lifecycle)
        let cancelled = reporting.cancelling(message: message, at: dependencies.now())
        appendTransition(cancelled.state, at: cancelled.finishedAt)
        await persistRecord(
            for: cancelled,
            syncResult: nil,
            failureMessage: cancelled.failureMessage,
            finishedAt: cancelled.finishedAt
        )
        publishCompleted(cancelled)
        startPendingRun()
        return .cancelled(cancelled)
    }

    private func startPendingRun() {
        guard !pendingTriggers.isEmpty else { return }
        let pending = pendingTriggers.removeFirst()
        _ = startRun(for: pending.request, startedAt: dependencies.now())
    }

    private func beginFixPlanning(from lifecycle: RunLifecycleSnapshot) -> RunLifecycleSnapshot {
        let planning = lifecycle.beginningFixPlanning()
        advance(planning)
        return planning
    }

    private func beginWriting(from lifecycle: RunLifecycleSnapshot) -> RunLifecycleSnapshot {
        let writing = lifecycle.beginningWriting()
        advance(writing)
        return writing
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
            timestamp: timestamp ?? dependencies.now()
        ))
    }

    private func persistRecord(
        for lifecycle: RunLifecycleSnapshot,
        syncResult: SyncResult?,
        failureMessage: String?,
        finishedAt: Date?
    ) async {
        let record = RunRecord(
            runID: lifecycle.runID,
            requestID: lifecycle.requestID,
            trigger: lifecycle.trigger,
            intent: lifecycle.intent,
            scope: lifecycle.scope,
            transitions: activeTransitions,
            syncSummary: syncResult.map(ActivitySyncSummary.init(result:)),
            failureMessage: failureMessage,
            startedAt: lifecycle.startedAt,
            finishedAt: finishedAt
        )

        do {
            try await dependencies.persistRunRecord(record)
        } catch {
            log.error("""
            Failed to persist run record \(lifecycle.runID.rawValue.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
        }
    }

    private func makeCreatedLifecycle(
        for request: RunRequest,
        startedAt: Date
    ) -> RunLifecycleSnapshot {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: request.requestedTestArtists,
            knownTrackCount: request.knownTrackCount,
            createdAt: startedAt,
            reason: request.trigger.rawValue
        )

        return RunLifecycleSnapshot(
            runID: RunID(),
            requestID: request.id,
            trigger: request.trigger,
            intent: request.intent,
            scope: scope,
            previewConfiguration: request.previewConfiguration,
            writeTarget: request.writeTarget,
            startedAt: startedAt,
            phase: .active(.created)
        )
    }

    private func publish(_ lifecycle: RunLifecycleSnapshot) {
        activeRun = lifecycle
        latestRun = lifecycle
        broadcast(lifecycle)
    }

    private func publishCompleted(_ lifecycle: RunLifecycleSnapshot) {
        activeRun = nil
        latestRun = lifecycle
        broadcast(lifecycle)
    }

    private func broadcast(_ lifecycle: RunLifecycleSnapshot) {
        var terminatedIDs: [UUID] = []

        for (id, continuation) in continuations {
            switch continuation.yield(lifecycle) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedIDs {
            continuations[id] = nil
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}
