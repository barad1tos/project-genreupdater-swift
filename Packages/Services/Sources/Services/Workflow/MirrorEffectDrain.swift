import Core
import Foundation
import OSLog

/// App-owned output seam for rebuilding presentation state after mirror changes.
public protocol MirrorProjectionOutput: Sendable {
    /// Rebuilds every app-owned projection from the committed mirror state.
    func refreshMirrorProjections() async throws
}

/// Publishes and clears the operator-visible state for deferred mirror effects.
public protocol MirrorEffectDrainReporting: Sendable {
    /// Publishes a non-fatal delivery failure while its effect remains durable for retry.
    func reportMirrorEffectFailure(_ detail: String) async
    /// Clears a previously published failure after the pending queue converges.
    func clearMirrorEffectFailure() async
}

/// Delivers durable mirror effects in stable order with at-least-once semantics.
public actor MirrorEffectDrain {
    private let store: any TrackStateStore
    private var cache: (any CacheService)?
    private var snapshot: (any LibrarySnapshotService)?
    private var projections: (any MirrorProjectionOutput)?
    private let reporter: (any MirrorEffectDrainReporting)?
    private let log = Logger(subsystem: "com.genreupdater", category: "MirrorEffectDrain")

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
        await deliverPendingEffects()
    }

    /// Delivers the complete backlog after a commit, retaining its accepted effect IDs as operational evidence.
    ///
    /// The IDs do not filter delivery; effects from older commits remain ahead of them in the store's stable order.
    ///
    /// - Parameter newlyCommittedEffectIDs: Effect IDs returned atomically with the accepted commit.
    public func drain(newlyCommittedEffectIDs: [UUID]) async {
        let committedEffectCount = Set(newlyCommittedEffectIDs).count
        log.info("Draining mirror effects after a commit with \(committedEffectCount, privacy: .public) new intents")
        await deliverPendingEffects(committedEffectCount: committedEffectCount)
    }

    private func deliverPendingEffects(committedEffectCount: Int? = nil) async {
        do {
            try await drainPendingEffects()
            await reporter?.clearMirrorEffectFailure()
        } catch {
            let detail = error.localizedDescription
            if let committedEffectCount {
                log.error(
                    "Mirror effect delivery failed after a commit with \(committedEffectCount, privacy: .public) new intents: \(detail, privacy: .private)"
                )
            } else {
                log.error("Pending mirror effect delivery failed: \(detail, privacy: .private)")
            }
            await reporter?.reportMirrorEffectFailure(detail)
        }
    }

    private func drainPendingEffects() async throws {
        while let pending = try await store.nextPendingMirrorEffect() {
            try Task.checkCancellation()
            try await execute(pending.effect)
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
