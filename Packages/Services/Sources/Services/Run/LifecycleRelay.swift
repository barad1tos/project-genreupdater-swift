import Foundation

/// Long-lived lifecycle broadcast that outlives any one orchestrator:
/// subscribers attach once and keep receiving across orchestrator
/// rebuilds, and a subscription made before the first orchestrator
/// exists starts delivering as soon as one is attached (ADR 0016 — one
/// canonical run lifecycle, served continuously).
public actor LifecycleRelay {
    /// Mirrors `RunOrchestrator.lifecycleBufferLimit`: the relay adds no
    /// buffering semantics of its own.
    private static let bufferLimit = 16

    private var subscribers: [UUID: LifecycleUpdateBuffer] = [:]
    private var latest: RunLifecycleSnapshot?
    private var forwardingTask: Task<Void, Never>?

    public init() {}

    /// New subscription; the latest known snapshot is pushed first so a
    /// late subscriber resynchronizes (the orchestrator's own semantic).
    public func subscribe() -> LifecycleUpdates {
        let id = UUID()
        let buffer = LifecycleUpdateBuffer(limit: Self.bufferLimit) { [weak self] in
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
        let updates = await orchestrator.lifecycleUpdates()
        forwardingTask = Task { [weak self] in
            for await lifecycle in updates {
                guard let self else { return }
                await self.broadcast(lifecycle)
            }
        }
    }

    private func broadcast(_ lifecycle: RunLifecycleSnapshot) {
        latest = lifecycle
        for buffer in subscribers.values {
            buffer.push(lifecycle)
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
