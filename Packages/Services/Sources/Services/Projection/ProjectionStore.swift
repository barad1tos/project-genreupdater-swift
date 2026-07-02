import Foundation

public actor ProjectionStore {
    private var currentActivityProjection: ActivityProjection
    private var latestIssuedActivityProjectionInputGeneration: UInt64
    private var latestAppliedActivityProjectionInputGeneration: UInt64
    private var activityContinuations: [UUID: AsyncStream<ActivityProjection>.Continuation]

    public init() {
        currentActivityProjection = .empty()
        latestIssuedActivityProjectionInputGeneration = 0
        latestAppliedActivityProjectionInputGeneration = 0
        activityContinuations = [:]
    }

    public func activityProjection() -> ActivityProjection {
        currentActivityProjection
    }

    public func activityUpdates() -> AsyncStream<ActivityProjection> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<ActivityProjection>.makeStream(bufferingPolicy: .bufferingNewest(1))

        registerActivityContinuation(continuation, id: subscriptionID)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeActivityContinuation(id: subscriptionID)
            }
        }

        return stream
    }

    public func nextActivityProjectionInputGeneration() -> UInt64 {
        latestIssuedActivityProjectionInputGeneration += 1
        return latestIssuedActivityProjectionInputGeneration
    }

    /// Replaces the activity projection when the optional input generation is newer.
    ///
    /// Returns the stored projection. If the input generation is stale, or if the
    /// new projection is content-identical to the current one, this returns the
    /// existing projection without advancing its revision or notifying subscribers.
    @discardableResult
    public func replaceActivityProjection(
        _ projection: ActivityProjection,
        inputGeneration: UInt64? = nil
    ) -> ActivityProjection {
        if let inputGeneration {
            guard inputGeneration > latestAppliedActivityProjectionInputGeneration else {
                return currentActivityProjection
            }
            latestIssuedActivityProjectionInputGeneration = max(
                latestIssuedActivityProjectionInputGeneration,
                inputGeneration
            )
            latestAppliedActivityProjectionInputGeneration = inputGeneration
        }

        let comparableProjection = projection.withRevision(currentActivityProjection.revision)
        guard comparableProjection != currentActivityProjection else {
            return currentActivityProjection
        }

        let storedProjection = projection.withRevision(currentActivityProjection.revision.advanced())

        currentActivityProjection = storedProjection
        broadcastActivityProjection(storedProjection)

        return storedProjection
    }

    private func registerActivityContinuation(
        _ continuation: AsyncStream<ActivityProjection>.Continuation,
        id: UUID
    ) {
        if case .terminated = continuation.yield(currentActivityProjection) {
            return
        }
        activityContinuations[id] = continuation
    }

    private func broadcastActivityProjection(_ projection: ActivityProjection) {
        var terminatedContinuationIDs: [UUID] = []

        for (id, continuation) in activityContinuations {
            switch continuation.yield(projection) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminatedContinuationIDs.append(id)
            @unknown default:
                break
            }
        }

        for id in terminatedContinuationIDs {
            activityContinuations[id] = nil
        }
    }

    private func removeActivityContinuation(id: UUID) {
        activityContinuations[id] = nil
    }
}
