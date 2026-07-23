import Core
import Foundation
import Testing
@testable import Services

@Suite("TriggerArbiter")
struct ArbiterTests {
    @Test("manual trigger queues after active background sync")
    func manualQueuesAfterBackground() {
        let active = Self.lifecycle(trigger: .backgroundSync, intent: .observeLibrary)
        let request = Self.request(
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
        let request = Self.request(
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
        let manualRequest = Self.request(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let recoveryRequest = Self.request(
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
        let request = Self.request(
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

    @Test("preview queues when configuration differs")
    func differentConfigurationQueues() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .previewFixes)
        let request = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 75)),
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued preview configuration, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("preview queues after the saved Discogs credential rotates")
    func rotatedCredentialQueues() {
        let activeConfiguration = previewConfig(discogsCredentialRevision: "revision-a")
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .previewFixes,
            previewConfiguration: activeConfiguration
        )
        let request = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(discogsCredentialRevision: "revision-b"),
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected rotated credential preview to queue, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("newest preview replaces the pending preview")
    func newestPreviewReplacesPending() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .previewFixes)
        let older = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 70)),
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let newest = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 80)),
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [PendingTrigger(request: older)],
            incoming: newest
        )

        guard case let .queue(pending) = decision else {
            Issue.record("Expected the latest preview to replace pending work, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [newest])
    }

    @Test("newest preview replaces a pending preview from another scope")
    func latestPreviewWins() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .previewFixes)
        let older = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 70)),
            requestedTestArtists: ["Artist A"],
            knownTrackCount: 75
        )
        let newest = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 80)),
            requestedTestArtists: ["Artist B"],
            knownTrackCount: 75
        )

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [PendingTrigger(request: older)],
            incoming: newest
        )

        guard case let .queue(pending) = decision else {
            Issue.record("Expected the latest preview scope to replace pending work, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [newest])
    }

    @Test("active preview clears a stale pending preview when resubmitted")
    func dropsStalePreviews() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .previewFixes)
        let firstStale = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 70)),
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let secondStale = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(UpdateOptions(minConfidence: 80)),
            requestedTestArtists: ["Other Artist"],
            knownTrackCount: nil
        )
        guard let activeConfiguration = active.previewConfiguration else {
            Issue.record("Expected active preview configuration")
            return
        }
        let incoming = RunRequest.preview(
            trigger: .manualCheck,
            configuration: activeConfiguration,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [PendingTrigger(request: firstStale), PendingTrigger(request: secondStale)],
            incoming: incoming
        )

        guard case .alreadyCovered([]) = decision else {
            Issue.record("Expected the active preview to clear stale pending work, got \(decision)")
            return
        }
    }

    @Test("preview with the same fingerprint is covered")
    func sameFingerprintCovered() {
        let active = Self.lifecycle(trigger: .manualCheck, intent: .previewFixes)
        let request = RunRequest.preview(
            trigger: .manualCheck,
            configuration: previewConfig(),
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let activeConfiguration = active.previewConfiguration
        #expect(activeConfiguration?.id != request.previewConfiguration?.id)
        #expect(activeConfiguration?.fingerprint == request.previewConfiguration?.fingerprint)

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case .alreadyCovered([]) = decision else {
            Issue.record("Expected matching preview fingerprint to be covered, got \(decision)")
            return
        }
    }

    @Test("equal trigger queues when test artist scope differs")
    func differentScopeQueues() {
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: ["Artist A"],
            knownTrackCount: 75
        )
        let request = Self.request(
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
        let request = Self.request(
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
        let pendingRequest = Self.request(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: 75
        )
        let request = Self.request(
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
            writeTarget: target
        )
        let request = RunRequest.manualWrite(input: Self.writeInput(target))

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
            writeTarget: Self.writeTarget("00000000-0000-0000-0000-000000000101")
        )
        let request = RunRequest.manualWrite(input: Self.writeInput(
            Self.writeTarget("00000000-0000-0000-0000-000000000102")
        ))

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected queued write target, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("distinct write targets remain pending")
    func writeTargetsRemainPending() {
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .writeFixes,
            writeTarget: Self.writeTarget("00000000-0000-0000-0000-000000000101")
        )
        let older = RunRequest.manualWrite(input: Self.writeInput(
            Self.writeTarget("00000000-0000-0000-0000-000000000102")
        ))
        let newest = RunRequest.manualWrite(input: Self.writeInput(
            Self.writeTarget("00000000-0000-0000-0000-000000000103")
        ))

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [PendingTrigger(request: older)],
            incoming: newest
        )

        guard case let .queue(pending) = decision else {
            Issue.record("Expected both write targets to remain queued, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [older, newest])
    }

    private static func request(
        trigger: RunTrigger,
        intent: RunIntent,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> RunRequest {
        switch intent {
        case .observeLibrary:
            RunRequest.observation(
                trigger: trigger,
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount
            )
        case .previewFixes:
            RunRequest.preview(
                trigger: trigger,
                configuration: previewConfig(),
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount
            )
        case .writeFixes:
            RunRequest.write(
                trigger: trigger,
                input: writeInput(
                    writeTarget("00000000-0000-0000-0000-000000000999"),
                    artists: requestedTestArtists,
                    knownTrackCount: knownTrackCount
                )
            )
        }
    }

    private static func lifecycle(
        trigger: RunTrigger,
        intent: RunIntent,
        requestedTestArtists: [String] = [],
        knownTrackCount: Int? = nil,
        writeTarget: FixPlanWriteTarget? = nil,
        previewConfiguration: FixPlanConfig? = nil
    ) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount,
            createdAt: startedAt,
            reason: trigger.rawValue
        )
        switch intent {
        case .observeLibrary:
            return RunLifecycleSnapshot(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: trigger,
                intent: intent,
                scope: scope,
                startedAt: startedAt,
                phase: .active(.syncingLibrary)
            )
        case .previewFixes:
            return RunLifecycleSnapshot(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: trigger,
                scope: scope,
                previewConfiguration: previewConfiguration ?? previewConfig(),
                startedAt: startedAt,
                phase: .active(.syncingLibrary)
            )
        case .writeFixes:
            return RunLifecycleSnapshot(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: trigger,
                scope: scope,
                writeTarget: writeTarget ?? Self.writeTarget("00000000-0000-0000-0000-000000000999"),
                startedAt: startedAt,
                phase: .active(.syncingLibrary)
            )
        }
    }

    private static func writeTarget(_ rawPlanID: String) -> FixPlanWriteTarget {
        guard let planID = UUID(uuidString: rawPlanID) else {
            preconditionFailure("Invalid write target UUID: \(rawPlanID)")
        }
        return FixPlanWriteTarget(
            planID: FixPlanID(rawValue: planID),
            planRevision: .initial,
            decisionRevision: .initial
        )
    }

    private static func writeInput(
        _ target: FixPlanWriteTarget,
        artists: [String] = [],
        knownTrackCount: Int? = nil
    ) -> FixPlanWriteInput {
        let capturedAt = Date(timeIntervalSince1970: 50)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: artists,
            knownTrackCount: knownTrackCount,
            createdAt: capturedAt,
            reason: "arbiter-test"
        )
        return FixPlanWriteInput(
            target: target,
            scope: scope,
            configuration: makeRunConfiguration(
                scopeID: scope.id,
                capturedAt: capturedAt,
                writeAuthority: .reviewedPlan
            ),
            workItems: [makeWorkItem(state: .prepared)]
        )
    }
}

private func previewConfig(
    _ options: UpdateOptions = UpdateOptions(),
    discogsCredentialRevision: String = ""
) -> FixPlanConfig {
    FixPlanConfig.capture(
        configuration: AppConfiguration(),
        options: options,
        capturedAt: Date(timeIntervalSince1970: 50),
        discogsCredentialRevision: discogsCredentialRevision
    )
}
