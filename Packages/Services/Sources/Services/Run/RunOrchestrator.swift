import Foundation
import OSLog

public actor RunOrchestrator {
    public struct Dependencies: Sendable {
        public let synchronizeLibrary: @Sendable () async throws -> SyncResult
        public let persistRunRecord: @Sendable (RunRecord) async throws -> Void
        public let now: @Sendable () -> Date

        public init(
            synchronizeLibrary: @escaping @Sendable () async throws -> SyncResult,
            persistRunRecord: @escaping @Sendable (RunRecord) async throws -> Void,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.synchronizeLibrary = synchronizeLibrary
            self.persistRunRecord = persistRunRecord
            self.now = now
        }
    }

    private let dependencies: Dependencies
    private let log = Logger(subsystem: "com.genreupdater", category: "RunOrchestrator")
    private var activeRun: RunLifecycleSnapshot?
    private var latestRun: RunLifecycleSnapshot?
    private var activeTransitions: [RunLifecycleTransition] = []
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
        let (stream, continuation) = AsyncStream<RunLifecycleSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
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
            return .alreadyRunning(activeRun)
        }

        // No suspension between the activeRun check and publish(created):
        // single-flight stays airtight without extra locking.
        let startedAt = dependencies.now()
        let created = makeCreatedLifecycle(for: request, startedAt: startedAt)
        activeTransitions = []
        advance(created, at: startedAt)
        let syncing = created.beginningSync()
        advance(syncing)

        // The run executes in an orchestrator-owned task: awaiting the value of
        // an unstructured Task's value never forwards the submitter's
        // cancellation into the run.
        let runTask = Task { await executeRun(from: syncing) }
        return await runTask.value
    }

    private func executeRun(from lifecycle: RunLifecycleSnapshot) async -> RunSubmissionResult {
        // Open record: a crash mid-run leaves it with finishedAt == nil as interrupted-run evidence.
        await persistRecord(for: lifecycle, syncResult: nil, failureMessage: nil, finishedAt: nil)

        do {
            let result = try await dependencies.synchronizeLibrary()
            let reporting = beginReporting(from: lifecycle)
            let completed = reporting.finishing(result: result, at: dependencies.now())
            appendTransition(completed.state, at: completed.finishedAt)
            await persistRecord(
                for: completed,
                syncResult: completed.syncResult,
                failureMessage: nil,
                finishedAt: completed.finishedAt
            )
            publishCompleted(completed)
            if case .finished(.completedNoOp, _) = completed.phase {
                return .completedNoOp(completed)
            }
            return .completed(completed)
        } catch is CancellationError {
            log.error("Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) cancelled")
            return await finishFailedRun(from: lifecycle, failureMessage: "Run cancelled")
        } catch {
            // Error descriptions stay private: sync errors can embed track or artist names.
            log.error("""
            Run \(lifecycle.runID.rawValue.uuidString, privacy: .public) failed with \
            \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            return await finishFailedRun(from: lifecycle, failureMessage: error.localizedDescription)
        }
    }

    private func finishFailedRun(
        from lifecycle: RunLifecycleSnapshot,
        failureMessage: String
    ) async -> RunSubmissionResult {
        let reporting = beginReporting(from: lifecycle)
        let failed = reporting.failing(message: failureMessage, at: dependencies.now())
        appendTransition(.failed, at: failed.finishedAt)
        await persistRecord(
            for: failed,
            syncResult: nil,
            failureMessage: failed.failureMessage,
            finishedAt: failed.finishedAt
        )
        publishCompleted(failed)
        return .failed(failed)
    }

    private func beginReporting(from lifecycle: RunLifecycleSnapshot) -> RunLifecycleSnapshot {
        let reporting = lifecycle.beginningReporting()
        advance(reporting)
        return reporting
    }

    /// Records the transition and publishes the snapshot in one step so the
    /// transitions log can never drift from the published lifecycle.
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
