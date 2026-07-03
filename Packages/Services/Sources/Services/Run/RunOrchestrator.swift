import Foundation

public actor RunOrchestrator {
    public struct Dependencies: Sendable {
        public let synchronizeLibrary: @Sendable () async throws -> SyncResult
        public let now: @Sendable () -> Date

        public init(
            synchronizeLibrary: @escaping @Sendable () async throws -> SyncResult,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.synchronizeLibrary = synchronizeLibrary
            self.now = now
        }
    }

    private let dependencies: Dependencies
    private var activeRun: RunLifecycleSnapshot?
    private var latestRun: RunLifecycleSnapshot?
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
        publish(created)
        let syncing = created.replacing(state: .syncingLibrary)
        publish(syncing)

        // The run executes in an orchestrator-owned task: awaiting the value
        // of a non-throwing Task does not forward the submitter's
        // cancellation into the run.
        let runTask = Task { await executeRun(from: syncing) }
        return await runTask.value
    }

    private func executeRun(from lifecycle: RunLifecycleSnapshot) async -> RunSubmissionResult {
        do {
            let result = try await dependencies.synchronizeLibrary()
            let completed = makeCompletedLifecycle(from: lifecycle, result: result)
            publishCompleted(completed)
            return result.hasChanges ? .completed(completed) : .completedNoOp(completed)
        } catch {
            let failed = lifecycle.replacing(
                state: .failed,
                failureMessage: error.localizedDescription,
                finishedAt: dependencies.now()
            )
            publishCompleted(failed)
            return .failed(failed)
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
            state: .created,
            scope: scope,
            syncResult: nil,
            failureMessage: nil,
            startedAt: startedAt,
            finishedAt: nil
        )
    }

    private func makeCompletedLifecycle(
        from lifecycle: RunLifecycleSnapshot,
        result: SyncResult
    ) -> RunLifecycleSnapshot {
        lifecycle.replacing(
            state: result.hasChanges ? .completed : .completedNoOp,
            syncResult: result,
            finishedAt: dependencies.now()
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
