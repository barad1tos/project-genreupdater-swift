import Core
import Foundation
import Services

/// The backend-owned lifecycle observer (ADR 0013/0016): converts run
/// lifecycle and checkpoint boundaries into projection publishes so the
/// chain lives with the dependency graph, not inside a window-scoped
/// view. Started from `initialize()` AFTER the orchestrator exists — a
/// subscription made earlier would receive an empty stream.
extension AppDependencies {
    func startLifecycleProjectionObserver() {
        lifecycleObserverTask?.cancel()
        lifecycleObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await lifecycle in await self.runLifecycleUpdates() {
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
        await republishActivityProjection()
        if !lifecycle.isActive {
            if lifecycle.intent == .previewFixes {
                await refreshFixPlanProjection()
            }
            await refreshReportsProjection()
        }
        if lifecycle.runID != lastChromeLifecycleRunID || lifecycle.state != lastChromeLifecycleState {
            lastChromeLifecycleRunID = lifecycle.runID
            lastChromeLifecycleState = lifecycle.state
            await refreshChromeProjection()
        }
    }
}
