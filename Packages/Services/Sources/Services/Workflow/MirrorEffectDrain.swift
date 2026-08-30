import Core
import Foundation
import OSLog

/// App-owned output seam for rebuilding Fix Plan, Reports, Activity, and Chrome after mirror changes.
public protocol MirrorProjectionOutput: Sendable {
    /// Rebuilds the mirror-dependent workflow projections currently owned by the app boundary.
    func refreshMirrorProjections() async throws
}

/// Classified delivery failure for an effect that remains durable for retry or repair.
public struct MirrorEffectDrainFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case temporary
        case corruptedQueue
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// Publishes and clears the operator-visible state for deferred mirror effects.
public protocol MirrorEffectDrainReporting: Sendable {
    /// Publishes a non-fatal delivery failure while its effect remains durable for retry.
    func reportMirrorEffectFailure(_ failure: MirrorEffectDrainFailure) async
    /// Clears a previously published failure after the pending queue converges.
    func clearMirrorEffectFailure() async
}

/// Delivers durable mirror effects in stable order with at-least-once semantics.
public actor MirrorEffectDrain {
    private enum DrainPolicy {
        case ordered
        case coalescingGlobalEffects

        func combined(with other: Self) -> Self {
            if self == .coalescingGlobalEffects || other == .coalescingGlobalEffects {
                return .coalescingGlobalEffects
            }
            return .ordered
        }
    }

    private let store: any TrackStateStore
    private var cache: (any CacheService)?
    private var snapshot: (any LibrarySnapshotService)?
    private var projections: (any MirrorProjectionOutput)?
    private let reporter: (any MirrorEffectDrainReporting)?
    private let log = Logger(subsystem: "com.genreupdater", category: "MirrorEffectDrain")
    private var isDraining = false
    private var queuedDrainPolicy: DrainPolicy?
    private var drainWaiters: [CheckedContinuation<Bool, Never>] = []
    var hasQueuedDrainRequest: Bool {
        !drainWaiters.isEmpty
    }

    public init(
        store: any TrackStateStore,
        cache: (any CacheService)?,
        snapshot: (any LibrarySnapshotService)?,
        projections: (any MirrorProjectionOutput)?,
        reporter: (any MirrorEffectDrainReporting)? = nil
    ) {
        self.store = store
        self.cache = cache
        self.snapshot = snapshot
        self.projections = projections
        self.reporter = reporter
    }

    /// Replaces runtime-derived targets before delivery resumes.
    public func updateTargets(
        cache: (any CacheService)?,
        snapshot: (any LibrarySnapshotService)?,
        projections: (any MirrorProjectionOutput)?
    ) {
        self.cache = cache
        self.snapshot = snapshot
        self.projections = projections
    }

    /// Delivers every pending effect in the store's stable order.
    public func drain() async {
        await requestDrain(policy: .ordered)
    }

    /// Delivers the complete backlog after a commit, using the new effect count for diagnostics.
    ///
    /// The IDs do not filter delivery; effects from older commits remain ahead of them in the store's stable order.
    ///
    /// - Parameter newlyCommittedEffectIDs: Effect IDs returned atomically with the accepted commit.
    public func drain(newlyCommittedEffectIDs: [UUID]) async {
        let committedEffectCount = Set(newlyCommittedEffectIDs).count
        log.info("Draining mirror effects after a commit with \(committedEffectCount, privacy: .public) new intents")
        await requestDrain(policy: .ordered, committedEffectCount: committedEffectCount)
    }

    /// Delivers one finalized batch while collapsing its snapshot and projection work.
    func drainBatchEffects() async {
        await requestDrain(policy: .coalescingGlobalEffects)
    }

    private func requestDrain(policy: DrainPolicy, committedEffectCount: Int? = nil) async {
        guard !isDraining else {
            queuedDrainPolicy = queuedDrainPolicy?.combined(with: policy) ?? policy
            let shouldTakeOver = await withCheckedContinuation { drainWaiters.append($0) }
            guard shouldTakeOver else { return }
            await runDrainLoop()
            return
        }

        isDraining = true
        await runDrainLoop(initialPolicy: policy, committedEffectCount: committedEffectCount)
    }

    private func runDrainLoop(
        initialPolicy: DrainPolicy? = nil,
        committedEffectCount: Int? = nil
    ) async {
        var policy = initialPolicy ?? takeQueuedDrainPolicy()
        var diagnosticCount = committedEffectCount
        while let currentPolicy = policy {
            await deliverPendingEffects(
                policy: currentPolicy,
                committedEffectCount: diagnosticCount
            )
            diagnosticCount = nil
            if Task.isCancelled, hasQueuedDrainRequest {
                let nextLeader = drainWaiters.removeFirst()
                nextLeader.resume(returning: true)
                return
            }
            policy = takeQueuedDrainPolicy()
        }
        isDraining = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
    }

    private func takeQueuedDrainPolicy() -> DrainPolicy? {
        defer { queuedDrainPolicy = nil }
        return queuedDrainPolicy
    }

    private func deliverPendingEffects(
        policy: DrainPolicy,
        committedEffectCount: Int? = nil
    ) async {
        do {
            switch policy {
            case .ordered:
                try await drainPendingEffects()
            case .coalescingGlobalEffects:
                try await drainBatchPendingEffects()
            }
            await reporter?.clearMirrorEffectFailure()
        } catch {
            let failure = Self.failure(from: error)
            if let committedEffectCount {
                log.error(
                    "Mirror effect delivery failed after a commit with \(committedEffectCount, privacy: .public) new intents: \(failure.detail, privacy: .private)"
                )
            } else {
                log.error("Pending mirror effect delivery failed: \(failure.detail, privacy: .private)")
            }
            await reporter?.reportMirrorEffectFailure(failure)
        }
    }

    private static func failure(from error: any Error) -> MirrorEffectDrainFailure {
        MirrorEffectDrainFailure(
            kind: error is MirrorEffectPersistenceError ? .corruptedQueue : .temporary,
            detail: error.localizedDescription
        )
    }

    private func drainPendingEffects() async throws {
        while let pending = try await store.nextPendingMirrorEffect() {
            try Task.checkCancellation()
            try await execute(pending.effect)
            try Task.checkCancellation()
            try await store.completeMirrorEffect(id: pending.id)
        }
    }

    private func drainBatchPendingEffects() async throws {
        let pendingEffects = try await store.pendingMirrorEffects()
        let snapshotEffects = pendingEffects.filter { $0.effect == .invalidateSnapshot }
        let projectionEffects = pendingEffects.filter { $0.effect == .refreshProjections }

        for pending in pendingEffects where !Self.isGlobal(pending.effect) {
            try Task.checkCancellation()
            try await execute(pending.effect)
            try Task.checkCancellation()
            try await store.completeMirrorEffect(id: pending.id)
        }
        try await executeOnce(.invalidateSnapshot, for: snapshotEffects)
        try await executeOnce(.refreshProjections, for: projectionEffects)
    }

    private static func isGlobal(_ effect: MirrorEffect) -> Bool {
        switch effect {
        case .invalidateSnapshot, .refreshProjections:
            true
        case .invalidateAlbumYear, .invalidateAPIResults:
            false
        }
    }

    private func executeOnce(_ effect: MirrorEffect, for pendingEffects: [PendingMirrorEffect]) async throws {
        guard !pendingEffects.isEmpty else { return }
        try Task.checkCancellation()
        try await execute(effect)
        for pending in pendingEffects {
            try Task.checkCancellation()
            try await store.completeMirrorEffect(id: pending.id)
        }
    }

    private func execute(_ effect: MirrorEffect) async throws {
        switch effect {
        case let .invalidateAlbumYear(identity):
            guard let cache else { throw MirrorEffectDrainError.cacheUnavailable }
            try await cache.invalidateAlbum(artist: identity.artist, album: identity.album)
        case let .invalidateAPIResults(identity):
            guard let cache else { throw MirrorEffectDrainError.cacheUnavailable }
            try await cache.invalidateCachedAPIResults(artist: identity.artist, album: identity.album)
        case .invalidateSnapshot:
            guard let snapshot else { throw MirrorEffectDrainError.snapshotUnavailable }
            try await snapshot.clearSnapshot()
        case .refreshProjections:
            guard let projections else { throw MirrorEffectDrainError.projectionOutputUnavailable }
            try await projections.refreshMirrorProjections()
        }
    }
}

/// Reports that a pending effect cannot reach its configured runtime target.
public enum MirrorEffectDrainError: LocalizedError, Equatable, Sendable {
    case cacheUnavailable
    case snapshotUnavailable
    case projectionOutputUnavailable

    public var errorDescription: String? {
        switch self {
        case .cacheUnavailable:
            "Mirror effect drain has no cache target"
        case .snapshotUnavailable:
            "Mirror effect drain has no library snapshot target"
        case .projectionOutputUnavailable:
            "Mirror effect drain has no projection output"
        }
    }
}
