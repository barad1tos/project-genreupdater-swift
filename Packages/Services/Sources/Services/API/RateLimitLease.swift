import Foundation

// Safety: mutable state is lock-guarded; the remaining properties are immutable and Sendable.
/// Owns a reserved token until the request is dispatched or the reservation is cancelled.
final class RateLimitLease: @unchecked Sendable {
    private enum State {
        case reserved
        case committed
        case released
    }

    private let limiter: TokenBucketRateLimiter
    private let lock = NSLock()
    private var state = State.reserved

    init(limiter: TokenBucketRateLimiter) {
        self.limiter = limiter
    }

    /// Consumes the token permanently. Call immediately after dispatch, before awaiting the response.
    func commit() {
        lock.withLock {
            switch state {
            case .reserved:
                state = .committed
            case .committed:
                break
            case .released:
                assertionFailure("Cannot commit a released rate-limit lease")
            }
        }
    }

    func cancel() async {
        guard markReleased() else { return }
        await limiter.release()
    }

    deinit {
        guard markReleased() else { return }
        let limiter = limiter
        Task { await limiter.release() }
    }

    private func markReleased() -> Bool {
        lock.withLock {
            guard case .reserved = state else { return false }
            state = .released
            return true
        }
    }
}
