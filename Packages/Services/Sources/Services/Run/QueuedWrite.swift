import Foundation

/// Why the freshness of a queued write's consent could not be proven.
public enum QueuedWriteConsentGap: Equatable, Sendable {
    /// No freshness source is wired — a wiring gap, not user staleness.
    case sourceMissing
    /// The plan has no current decision to compare against.
    case noCurrentDecision
}

/// How an explicit attempt to release the queued write concluded.
public enum QueuedWriteRelease: Equatable, Sendable {
    /// The queued request was handed to the normal submit path; the wrapped
    /// result carries what actually happened — `.alreadyCovered`/`.queued`
    /// while another run is active, or the started run's own result. (No
    /// suspension separates the hold re-validation from submit, so a
    /// re-engaged hold cannot surface here.)
    case released(RunSubmissionResult)
    /// A recovery hold still blocks writes; nothing was released. Returned
    /// whether or not anything is queued.
    case blocked
    /// Nothing is queued.
    case empty
    /// The slot changed while freshness was being verified; nothing was
    /// released and the newer slot content is untouched.
    case superseded
    /// The current decision no longer matches the queued consent; the slot
    /// is cleared and nothing was written.
    case stale
    /// Freshness could not be proven; nothing was written and the slot is
    /// retained so a transient lookup failure cannot destroy the intent.
    case unverifiable(QueuedWriteConsentGap)
}

extension RunOrchestrator {
    /// Retains at most ONE write request while a recovery hold blocks writes
    /// (slice 5 bounded queued plan). A same-plan request with a
    /// lexicographically same-or-newer (planRevision, decisionRevision) pair
    /// supersedes the slot — on equal revisions the latest apply wins; a
    /// different plan or older consent leaves the current request in place.
    /// The slot is in-memory only: a restart keeps the durable plan and
    /// decision but drops the queued intent, so nothing can silently restart.
    func retainWriteBehindRecovery(_ request: RunRequest) {
        // Only writeFixes requests reach this point, and those always carry
        // a target; a missing one must not silently occupy the slot.
        guard let incoming = request.writeTarget else { return }
        if let current = queuedWrite?.writeTarget {
            let supersedes = incoming.planID == current.planID
                && (incoming.planRevision > current.planRevision
                    || (incoming.planRevision == current.planRevision
                        && incoming.decisionRevision >= current.decisionRevision))
            guard supersedes else {
                log.info("""
                Queued-write slot kept plan \(current.planID.rawValue.uuidString, privacy: .public); \
                dropped request for plan \(incoming.planID.rawValue.uuidString, privacy: .public)
                """)
                return
            }
            log.info("""
            Queued write superseded for plan \(incoming.planID.rawValue.uuidString, privacy: .public) at \
            revision \(incoming.planRevision.value, privacy: .public)
            """)
        }
        queuedWrite = request
    }

    public func queuedWriteRequest() -> RunRequest? {
        queuedWrite
    }

    /// Every plan a write request currently holds in flight: the queued-write
    /// slot, a release in progress, requests parked behind the active run,
    /// and the active run's own target. Fix-plan retention must keep all of
    /// them — a parked write's plan is referenced by no persisted record
    /// until its run starts.
    public func inFlightWritePlanIDs() -> Set<FixPlanID> {
        var planIDs = Set<FixPlanID>()
        if let queued = queuedWrite?.writeTarget?.planID {
            planIDs.insert(queued)
        }
        if let releasing = releasingWrite?.writeTarget?.planID {
            planIDs.insert(releasing)
        }
        for pending in pendingTriggers {
            if let planID = pending.request.writeTarget?.planID {
                planIDs.insert(planID)
            }
        }
        if let active = activeRun?.writeTarget?.planID {
            planIDs.insert(active)
        }
        return planIDs
    }

    public func discardQueuedWrite() {
        if let target = queuedWrite?.writeTarget {
            log.info("Queued write discarded for plan \(target.planID.rawValue.uuidString, privacy: .public)")
        }
        queuedWrite = nil
    }

    /// Releases the queued write through the normal submit path — the only
    /// way the orchestrator will run it (slice 5: explicit "Continue
    /// writes", never a silent restart). Consent must still be the current
    /// decision; unverifiable freshness refuses the write but keeps the
    /// slot. Double-submission of a released request is absorbed by the
    /// trigger arbiter's writeTarget-equality coverage.
    public func releaseQueuedWrite() async -> QueuedWriteRelease {
        guard !recoveryState.hasWriteBlock else { return .blocked }
        guard let request = queuedWrite, let target = request.writeTarget else {
            return .empty
        }
        guard let currentTarget = dependencies.currentDecisionTarget else {
            log.error("Queued write release unverifiable: no consent source wired")
            return .unverifiable(.sourceMissing)
        }

        let current = await currentTarget(target.planID)
        // Actor reentrancy: the lookup may have admitted a hold, discarded,
        // or superseded the slot — re-validate before touching anything.
        guard !recoveryState.hasWriteBlock else { return .blocked }
        guard let held = queuedWrite else { return .empty }
        guard held.id == request.id else { return .superseded }
        guard let current else {
            log.error("""
            Queued write release unverifiable: plan \(target.planID.rawValue.uuidString, privacy: .public) \
            has no current decision
            """)
            return .unverifiable(.noCurrentDecision)
        }
        guard current == target else {
            queuedWrite = nil
            log.info("""
            Queued write cleared: consent for plan \(target.planID.rawValue.uuidString, privacy: .public) is stale
            """)
            return .stale
        }
        queuedWrite = nil
        log.info("Queued write released for plan \(target.planID.rawValue.uuidString, privacy: .public)")
        // Keep the plan visible to retention while the request is neither in
        // the slot nor yet parked/started by submit.
        releasingWrite = request
        defer { releasingWrite = nil }
        return await .released(submit(request))
    }
}
