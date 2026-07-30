import Foundation

extension RunOrchestrator {
    /// Retains at most ONE write request while a recovery hold blocks writes
    /// (slice 5 bounded queued plan). A newer revision of the same plan
    /// supersedes the slot; anything else leaves the first request in place.
    /// The slot is in-memory only: a restart keeps the durable plan and
    /// decision but drops the queued intent, so nothing can silently restart.
    func retainWriteBehindRecovery(_ request: RunRequest) {
        if let queued = queuedWrite {
            let supersedes = queued.writeTarget.map { current in
                request.writeTarget?.planID == current.planID
                    && (request.writeTarget?.planRevision ?? .initial) >= current.planRevision
            } ?? false
            guard supersedes else { return }
        }
        queuedWrite = request
    }

    public func queuedWriteRequest() -> RunRequest? {
        queuedWrite
    }

    public func discardQueuedWrite() {
        queuedWrite = nil
    }
}
