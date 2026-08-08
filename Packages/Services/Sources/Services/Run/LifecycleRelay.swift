import Foundation

/// Long-lived lifecycle broadcast that outlives any one orchestrator:
/// subscribers attach once and keep receiving across orchestrator
/// rebuilds, and a subscription made before the first orchestrator
/// exists starts delivering as soon as one is attached (ADR 0016 — one
/// canonical run lifecycle, served continuously).
public actor LifecycleRelay {
    private var subscribers: [UUID: LifecycleUpdateBuffer] = [:]
    private var latest: RunLifecycleSnapshot?
    private var forwardingTask: Task<Void, Never>?
    /// Advances on every attach; broadcasts from a superseded forwarding
    /// task carry the old generation and are dropped, so a detached
    /// orchestrator can never interleave after its replacement.
    private var attachGeneration = 0

    public init() {
        // Stateless construction: attach(to:) wires the first upstream.
    }

    /// New subscription; the latest known snapshot is pushed first so a
    /// late subscriber resynchronizes (the orchestrator's own semantic).
    public func subscribe() -> LifecycleUpdates {
        let id = UUID()
        let buffer = LifecycleUpdateBuffer(limit: RunOrchestrator.lifecycleBufferLimit) { [weak self] in
            Task { await self?.remove(id) }
        }
        if let latest {
            buffer.push(latest)
        }
        subscribers[id] = buffer
        return LifecycleUpdates(buffer: buffer)
    }

    /// Rewires the upstream: cancels the previous forwarding task and
    /// forwards every element of the new orchestrator's subscription
    /// into all live subscriber buffers.
    public func attach(to orchestrator: RunOrchestrator) async {
        forwardingTask?.cancel()
        attachGeneration += 1
        let generation = attachGeneration
        // An ACTIVE snapshot of the detached orchestrator would replay
        // to new subscribers as a run whose terminal boundary can never
        // arrive through the relay — a phantom running state (the
        // pitfall-50 class). Terminal snapshots stay: they are honest
        // history and keep late-subscriber continuity.
        if latest?.isActive == true {
            latest = nil
        }
        let updates = await orchestrator.lifecycleUpdates()
        forwardingTask = Task { [weak self] in
            for await lifecycle in updates {
                guard let self else { return }
                await self.broadcast(lifecycle, generation: generation)
            }
        }
    }

    func subscriberCount() -> Int {
        subscribers.count
    }

    func latestSnapshot() -> RunLifecycleSnapshot? {
        latest
    }

    private func broadcast(_ lifecycle: RunLifecycleSnapshot, generation: Int) {
        guard generation == attachGeneration else { return }
        latest = lifecycle
        for buffer in subscribers.values {
            buffer.push(lifecycle)
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
