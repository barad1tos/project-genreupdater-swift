import Foundation

/// Generation-based invalidation for restartable async chains: callers
/// snapshot `begin()`'s token and check `isCurrent(_:)` after every
/// await; `invalidate()` (or a newer `begin()`) makes older tokens
/// stale. Replaces the per-surface UUID + guard pattern.
@MainActor
final class RequestTokenGate {
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        generation += 1
        return generation
    }

    func invalidate() {
        generation += 1
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == generation
    }
}
