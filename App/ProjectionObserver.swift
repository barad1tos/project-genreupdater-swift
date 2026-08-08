import Core
import Foundation
import Services

/// The backend-owned lifecycle observer (ADR 0013/0016): converts run
/// lifecycle and checkpoint boundaries into projection publishes so the
/// chain lives with the dependency graph, not inside a window-scoped
/// view. Started from `initialize()` AFTER the orchestrator exists — a
/// subscription made earlier would receive an empty stream.
extension AppDependencies {
    /// A re-initialize rebuilds the orchestrator: the previous
    /// session's snapshot and throttle keys must not survive into the
    /// new one, or chrome serves a dead run and the first new boundary
    /// can be throttled away. Called at initialize() ENTRY so even the
    /// bootstrap publishes read a cleared snapshot, and again on
    /// observer restart to close the unawaited-cancel race.
    func resetLifecycleProjectionState() {
        currentLifecycleSnapshot = nil
        lastChromeLifecycleRunID = nil
        lastChromeLifecycleState = nil
    }

    func startLifecycleProjectionObserver() {
        lifecycleObserverTask?.cancel()
        resetLifecycleProjectionState()
        lifecycleObserverTask = Task { @MainActor [weak self] in
            guard let updates = await self?.runLifecycleUpdates() else { return }
            for await lifecycle in updates {
                guard let self else { return }
                await self.publishLifecycleBoundary(lifecycle)
            }
        }
    }

    /// One boundary, one publish pass. Chrome re-derives only at
    /// (run, state) boundaries: per-item write checkpoints re-emit the
    /// same state, and skipping them keeps the probe cost (file
    /// comparisons, workspace scan, count query) off the write path
    /// where the projection could not change anyway.
    func publishLifecycleBoundary(_ lifecycle: RunLifecycleSnapshot) async {
        currentLifecycleSnapshot = lifecycle
        // Terminal dependencies FIRST: activity embeds fix-plan and
        // reports truth, so it must publish after them or a headless
        // terminal boundary leaves activity a boundary stale.
        if !lifecycle.isActive {
            if lifecycle.intent == .previewFixes {
                await refreshFixPlanProjection()
            }
            await refreshReportsProjection()
        }
        await republishActivityProjection()
        if lifecycle.runID != lastChromeLifecycleRunID || lifecycle.state != lastChromeLifecycleState {
            lastChromeLifecycleRunID = lifecycle.runID
            lastChromeLifecycleState = lifecycle.state
            await refreshChromeProjection()
        }
    }
}
