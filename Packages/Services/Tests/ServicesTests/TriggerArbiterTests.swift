import Foundation
import Testing
@testable import Services

@Suite("TriggerArbiter")
struct TriggerArbiterTests {
    @Test("manual trigger queues after active background sync")
    func manualQueuesAfterBackground() {
        let active = Self.lifecycle(trigger: .backgroundSync, intent: .observeLibrary)
        let request = RunRequest(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: nil, incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued trigger, got \(decision)")
            return
        }
        #expect(pending.request == request)
        #expect(pending.coalescedTriggers == [.manualCheck])
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

        let decision = TriggerArbiter.decide(active: active, pending: nil, incoming: request)

        guard case .alreadyCovered(nil) = decision else {
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

        let decision = TriggerArbiter.decide(active: active, pending: pending, incoming: recoveryRequest)

        guard case let .queue(updatedPending) = decision else {
            Issue.record("Expected queued recovery trigger, got \(decision)")
            return
        }
        #expect(updatedPending.request == recoveryRequest)
        #expect(updatedPending.coalescedTriggers == [.manualCheck, .recovery])
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

        let decision = TriggerArbiter.decide(active: active, pending: nil, incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued preview intent, got \(decision)")
            return
        }
        #expect(pending.request == request)
        #expect(pending.coalescedTriggers == [.manualCheck])
    }

    private static func lifecycle(
        trigger: RunTrigger,
        intent: RunIntent
    ) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 100)
        return RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: trigger,
            intent: intent,
            scope: .capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: trigger.rawValue
            ),
            startedAt: startedAt,
            phase: .active(.syncingLibrary)
        )
    }
}
