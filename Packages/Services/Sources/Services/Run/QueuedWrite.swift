import Foundation

/// How an explicit attempt to release the queued write concluded.
public enum QueuedWriteRelease: Equatable, Sendable {
    /// The queued request was resubmitted through the normal run path.
    case released(RunSubmissionResult)
    /// A recovery hold still blocks writes; the slot is retained.
    case blocked
    /// Nothing is queued.
    case empty
    /// The queued consent is no longer the current decision (or could not be
    /// verified); the slot is cleared and nothing was written.
    case stale
}

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

    /// Releases the queued write through the normal submit path — the ONLY
    /// way it may run (slice 5: explicit "Continue writes", never a silent
    /// restart). Consent must still be the current decision; anything
    /// unverifiable fails closed with the slot cleared.
    public func releaseQueuedWrite() async -> QueuedWriteRelease {
        guard !recoveryState.hasWriteBlock else { return .blocked }
        guard let request = queuedWrite else { return .empty }
        guard let currentTarget = dependencies.currentDecisionTarget,
              let target = request.writeTarget,
              await currentTarget(target.planID) == target
        else {
            queuedWrite = nil
            return .stale
        }
        queuedWrite = nil
        return await .released(submit(request))
    }
}
