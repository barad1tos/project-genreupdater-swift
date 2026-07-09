import Foundation
import Testing
@testable import Services

@Suite("TriggerArbiter")
struct ArbiterTests {
    @Test("manual trigger queues after active background sync")
    func manualQueuesAfterBackground() {
        let active = Self.lifecycle(trigger: .backgroundSync, intent: .observeLibrary)
        let request = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued trigger, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("background trigger is already covered by active manual run")
    func backgroundCoveredByManual() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .observeLibrary)
        let request = RunRequest(
            trigger: .backgroundSync,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case .alreadyCovered([]) = decision else {
            Issue.record("Expected already covered trigger, got \(decision)")
            return
        }
    }

    @Test("stronger trigger replaces existing pending request")
    func recoveryReplacesPending() {
        let active = Self.lifecycle(trigger: .backgroundSync, intent: .observeLibrary)
        let manualRequest = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let recoveryRequest = RunRequest(
            trigger: .recovery,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let pending = PendingTrigger(request: manualRequest)

        let decision = TriggerArbiter.decide(active: active, pending: [pending], incoming: recoveryRequest)

        guard case let .queue(updatedPending) = decision else {
            Issue.record("Expected queued recovery trigger, got \(decision)")
            return
        }
        #expect(updatedPending.map(\.request) == [recoveryRequest])
    }

    @Test("preview intent queues after active observation")
    func previewQueuesAfterObserve() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .observeLibrary)
        let request = RunRequest(
            trigger: .manualCheck,
            intent: .previewFixes,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued preview intent, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("equal trigger queues when test artist scope differs")
    func differentScopeQueues() {
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: ["Artist A"],
            knownTrackCount: 75
        )
        let request = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: ["Artist B"],
            knownTrackCount: 75
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued trigger, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("full library active run covers equal scoped trigger")
    func fullLibraryCovers() {
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: 75
        )
        let request = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: ["Artist B"],
            knownTrackCount: 75
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case .alreadyCovered([]) = decision else {
            Issue.record("Expected already covered trigger, got \(decision)")
            return
        }
    }

    @Test("pending full library run covers equal scoped trigger")
    func pendingLibraryCovers() {
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: ["Artist A"],
            knownTrackCount: 75
        )
        let pendingRequest = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: 75
        )
        let request = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: ["Artist B"],
            knownTrackCount: 75
        )
        let pending = PendingTrigger(request: pendingRequest)

        let decision = TriggerArbiter.decide(active: active, pending: [pending], incoming: request)

        guard case let .alreadyCovered(updatedPending) = decision else {
            Issue.record("Expected already covered trigger, got \(decision)")
            return
        }
        #expect(updatedPending == [pending])
    }

    @Test("equal write intent covers the same reviewed target")
    func writeCoversSameTarget() {
        let target = Self.writeTarget("00000000-0000-0000-0000-000000000101")
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .writeFixes,
            applyTarget: target
        )
        let request = RunRequest.manualWrite(
            target: target,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case .alreadyCovered([]) = decision else {
            Issue.record("Expected already covered write target, got \(decision)")
            return
        }
    }

    @Test("equal write intent queues a different reviewed target")
    func writeQueuesDifferentTarget() {
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .writeFixes,
            applyTarget: Self.writeTarget("00000000-0000-0000-0000-000000000101")
        )
        let request = RunRequest.manualWrite(
            target: Self.writeTarget("00000000-0000-0000-0000-000000000102"),
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued write target, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    private static func lifecycle(
        trigger: RunTrigger,
        intent: RunIntent,
        requestedTestArtists: [String] = [],
        knownTrackCount: Int? = nil,
        applyTarget: FixPlanApplyTarget? = nil
    ) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 100)
        return RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: trigger,
            intent: intent,
            scope: .capture(
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount,
                createdAt: startedAt,
                reason: trigger.rawValue
            ),
            applyTarget: applyTarget,
            startedAt: startedAt,
            phase: .active(.syncingLibrary)
        )
    }

    private static func writeTarget(_ rawPlanID: String) -> FixPlanApplyTarget {
        guard let planID = UUID(uuidString: rawPlanID) else {
            preconditionFailure("Invalid write target UUID: \(rawPlanID)")
        }
        return FixPlanApplyTarget(
            planID: FixPlanID(rawValue: planID),
            planRevision: .initial,
            decisionRevision: .initial
        )
    }
}
