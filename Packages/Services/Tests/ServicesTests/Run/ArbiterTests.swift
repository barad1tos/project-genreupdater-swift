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

    @Test("auto-fix is not covered by an active preview with the same inputs")
    func autoFixQueuesBehindPreview() {
        let configuration = previewConfig()
        let active = Self.previewLifecycle(configuration: configuration, mode: .preview)
        let request = RunRequest.preview(
            trigger: .manualCheck,
            configuration: configuration,
            mode: .autoFix,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected auto-fix policy to queue, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [request])
    }

    @Test("preview is not covered by active auto-fix with the same inputs")
    func previewQueuesBehindAutoFix() {
        let configuration = previewConfig()
        let active = Self.previewLifecycle(configuration: configuration, mode: .autoFix)
        let request = RunRequest.preview(
            trigger: .manualCheck,
            configuration: configuration,
            mode: .preview,
            requestedTestArtists: [],
            knownTrackCount: nil
        )

        let decision = TriggerArbiter.decide(active: active, pending: [], incoming: request)

        guard case let .queue(pending) = decision else {
            Issue.record("Expected preview policy to queue, got \(decision)")
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
        let input = Self.writeInput(target)
        let request = RunRequest.manualWrite(input: input)
        let active = RunLifecycleSnapshot(
            request: request,
            scope: input.scope,
            startedAt: Date(timeIntervalSince1970: 100),
            phase: .active(.writing)
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

    @Test("batch requests with different certificate evidence do not cover each other")
    func batchCertificatesRemainDistinct() {
        let scope = Self.admissionScope()
        let older = Self.batchRequest(trigger: .manualCheck, scope: scope, certificate: 101)
        let newest = Self.batchRequest(trigger: .manualCheck, scope: scope, certificate: 102)
        let active = Self.lifecycle(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: [],
            knownTrackCount: 2
        )

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [PendingTrigger(request: older)],
            incoming: newest
        )

        guard case let .queue(pending) = decision else {
            Issue.record("Expected distinct admission evidence to remain queued, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [older, newest])
    }

    @Test("lower-priority batch with different admission queues behind existing work")
    func lowerPriorityQueues() {
        let scope = Self.admissionScope()
        let active = Self.activeBatch(scope: scope, certificate: 201)
        let queuedRequest = Self.batchRequest(trigger: .fileSystemEvent, scope: scope, certificate: 202)
        let incoming = Self.batchRequest(trigger: .backgroundSync, scope: scope, certificate: 203)

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [PendingTrigger(request: queuedRequest)],
            incoming: incoming
        )

        guard case let .queue(pending) = decision else {
            Issue.record("Expected distinct lower-priority admission to queue, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [queuedRequest, incoming])
    }

    @Test("lower-priority batch is covered by queued matching admission")
    func pendingAdmissionCovers() {
        let scope = Self.admissionScope()
        let active = Self.activeBatch(scope: scope, certificate: 301)
        let queuedRequest = Self.batchRequest(trigger: .fileSystemEvent, scope: scope, certificate: 302)
        let incoming = Self.batchRequest(trigger: .backgroundSync, scope: scope, certificate: 302)
        let queued = PendingTrigger(request: queuedRequest)

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [queued],
            incoming: incoming
        )

        guard case let .alreadyCovered(pending) = decision else {
            Issue.record("Expected queued matching admission to cover incoming work, got \(decision)")
            return
        }
        #expect(pending == [queued])
    }

    @Test("intermediate batch replaces covered weaker work and preserves distinct pending work")
    func replacesCoveredPending() {
        let scope = Self.admissionScope()
        let otherScope = Self.admissionScope(["Other Artist"])
        let active = Self.activeBatch(scope: scope, certificate: 401)
        let differentAdmission = Self.batchRequest(trigger: .backgroundSync, scope: scope, certificate: 403)
        let covered = Self.batchRequest(trigger: .backgroundSync, scope: scope, certificate: 402)
        let differentScope = Self.batchRequest(trigger: .backgroundSync, scope: otherScope, certificate: 404)
        let incoming = Self.batchRequest(trigger: .fileSystemEvent, scope: scope, certificate: 402)

        let decision = TriggerArbiter.decide(
            active: active,
            pending: [
                PendingTrigger(request: differentAdmission),
                PendingTrigger(request: covered),
                PendingTrigger(request: differentScope),
            ],
            incoming: incoming
        )

        guard case let .queue(pending) = decision else {
            Issue.record("Expected intermediate trigger to replace only covered weaker work, got \(decision)")
            return
        }
        #expect(pending.map(\.request) == [differentAdmission, differentScope, incoming])
    }

    private static func batchRequest(
        trigger: RunTrigger,
        scope: ProcessingScopeSnapshot,
        certificate: Int
    ) -> RunRequest {
        RunRequest.batchUpdate(
            trigger: trigger,
            input: BatchRunInput(
                options: UpdateOptions(),
                trackCount: scope.knownTrackCount ?? 0,
                admission: processingAdmission(scope: scope, certificateID: certificateID(certificate))
            ),
            requestedTestArtists: scope.normalizedTestArtists,
            knownTrackCount: scope.knownTrackCount
        )
    }

    private static func activeBatch(scope: ProcessingScopeSnapshot, certificate: Int) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            request: batchRequest(trigger: .manualCheck, scope: scope, certificate: certificate),
            scope: scope,
            startedAt: Date(timeIntervalSince1970: 100),
            phase: .active(.writing)
        )
    }

    private static func admissionScope(_ artists: [String] = []) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot.capture(
            requestedTestArtists: artists,
            knownTrackCount: 2,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "arbiter-admission-test"
        )
    }

    private static func certificateID(_ number: Int) -> UUID {
        guard let certificateID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) else {
            preconditionFailure("Invalid certificate number: \(number)")
        }
        return certificateID
    }

    private static func request(
        trigger: RunTrigger,
        intent: RunIntent,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> RunRequest {
        switch intent {
        case .observeLibrary:
            return RunRequest.observation(
                trigger: trigger,
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount
            )
        case .previewFixes:
            return RunRequest.preview(
                trigger: trigger,
                configuration: previewConfig(),
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount
            )
        case .writeFixes:
            let input = writeInput(
                writeTarget("00000000-0000-0000-0000-000000000999"),
                artists: requestedTestArtists,
                knownTrackCount: knownTrackCount
            )
            return trigger == .manualCheck
                ? RunRequest.manualWrite(input: input)
                : RunRequest.automaticWrite(trigger: trigger, input: input)
        case .batchUpdate:
            let scope = ProcessingScopeSnapshot.capture(
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "arbiter-request"
            )
            return RunRequest.batchUpdate(
                trigger: trigger,
                input: BatchRunInput(
                    options: UpdateOptions(),
                    trackCount: knownTrackCount ?? 0,
                    admission: processingAdmission(scope: scope)
                ),
                requestedTestArtists: requestedTestArtists,
                knownTrackCount: knownTrackCount
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
        case .batchUpdate:
            return RunLifecycleSnapshot(
                runID: RunID(),
                request: .batchUpdate(
                    trigger: trigger,
                    input: BatchRunInput(
                        options: UpdateOptions(),
                        trackCount: knownTrackCount ?? 0,
                        admission: processingAdmission(scope: scope)
                    ),
                    requestedTestArtists: requestedTestArtists,
                    knownTrackCount: knownTrackCount
                ),
                scope: scope,
                startedAt: startedAt,
                phase: .active(.writing)
            )
        }
    }

    private static func previewLifecycle(
        configuration: FixPlanConfig,
        mode: RunProcessingMode
    ) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 100)
        let request = RunRequest.preview(
            trigger: .manualCheck,
            configuration: configuration,
            mode: mode,
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        return RunLifecycleSnapshot(
            runID: RunID(),
            request: request,
            scope: .capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: "arbiter-policy-test"
            ),
            startedAt: startedAt,
            phase: .active(.syncingLibrary)
        )
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
            admission: processingAdmission(scope: scope),
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
