import Core
import Foundation
import Services

/// Coordination state for a reload deferred behind a run: set by the
/// activity command path (queued run), the refused scope change, or a
/// menu action; advanced at run completion.
enum QueuedManualReload: Equatable {
    case waitingForActive(RunID)
    case waitingForQueued
}

struct QueuedReloadAdvance: Equatable {
    let next: QueuedManualReload?
    let shouldReload: Bool
}

func advanceQueuedReload(
    _ state: QueuedManualReload?,
    lifecycle: RunLifecycleSnapshot
) -> QueuedReloadAdvance {
    guard let state, lifecycle.finishedAt != nil else {
        return QueuedReloadAdvance(next: state, shouldReload: false)
    }

    switch state {
    case let .waitingForActive(runID) where lifecycle.runID == runID:
        return QueuedReloadAdvance(next: .waitingForQueued, shouldReload: false)
    case .waitingForActive, .waitingForQueued:
        return QueuedReloadAdvance(next: nil, shouldReload: true)
    }
}

/// The machine lives on the dependency graph so every surface — the
/// window, the activity commands, and the menus — coordinates through
/// one state (D4).
extension AppDependencies {
    /// Consumes the queued state for a terminal lifecycle and performs
    /// the reload when the machine says so.
    func advanceQueuedReloadForBoundary(_ lifecycle: RunLifecycleSnapshot) async {
        guard !lifecycle.isActive else { return }
        let advance = advanceQueuedReload(queuedManualReload, lifecycle: lifecycle)
        queuedManualReload = advance.next
        if advance.shouldReload {
            await loadLibrary(forceRefresh: true)
        }
    }
}
