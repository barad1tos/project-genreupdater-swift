import Core
import Foundation
import Testing
@testable import Services

@Suite("Queued writes behind recovery holds")
struct QueuedWriteTests {
    @Test("a write submitted under a hold is retained, not executed")
    func queuesWriteUnderHold() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let request = RunRequest.manualWrite(input: makeWriteInput())

        let result = await orchestrator.submit(request)

        guard case .recoveryRequired = result else {
            Issue.record("Expected the hold to keep blocking the write, got \(result)")
            return
        }
        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
        #expect(await orchestrator.currentLifecycle()?.intent != .writeFixes)
    }

    @Test("the slot is bounded to one request")
    func keepsFirstQueuedWrite() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let first = RunRequest.manualWrite(input: makeWriteInput())
        let second = RunRequest.manualWrite(input: makeWriteInput())
        _ = await orchestrator.submit(first)

        _ = await orchestrator.submit(second)

        #expect(await orchestrator.queuedWriteRequest()?.id == first.id)
    }

    @Test("a newer revision of the same plan supersedes the queued request")
    func replacesWithNewerRevision() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let planID = FixPlanID()
        let first = RunRequest.manualWrite(input: makeWriteInput(
            planID: planID,
            planRevision: .initial
        ))
        let successor = RunRequest.manualWrite(input: makeWriteInput(
            planID: planID,
            planRevision: FixPlanRevision.initial.advanced()
        ))
        _ = await orchestrator.submit(first)

        _ = await orchestrator.submit(successor)

        #expect(await orchestrator.queuedWriteRequest()?.id == successor.id)
    }

    @Test("without a hold the write path is untouched")
    func submitsNormallyWithoutHold() async {
        let orchestrator = makeOrchestrator()
        let request = RunRequest.manualWrite(input: makeWriteInput())

        let result = await orchestrator.submit(request)

        if case .recoveryRequired = result {
            Issue.record("A write without a hold must not be blocked")
        }
        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("discarding empties the slot")
    func discardsQueuedWrite() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        _ = await orchestrator.submit(RunRequest.manualWrite(input: makeWriteInput()))

        await orchestrator.discardQueuedWrite()

        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("release is refused while the hold is still engaged")
    func refusesReleaseUnderHold() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let request = RunRequest.manualWrite(input: makeWriteInput())
        _ = await orchestrator.submit(request)

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .blocked)
        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
    }

    @Test("release with current consent resubmits the queued write")
    func releasesFreshQueuedWrite() async {
        let holdID = UUID()
        let input = makeWriteInput()
        let records = RunRecordSpy()
        let orchestrator = makeOrchestrator(
            persistRunRecord: { await records.append($0) },
            currentDecisionTarget: { planID in
                planID == input.target.planID ? input.target : nil
            }
        )
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        guard case .released = outcome else {
            Issue.record("Expected the queued write to be resubmitted, got \(outcome)")
            return
        }
        #expect(await orchestrator.queuedWriteRequest() == nil)
        // The released run must be THE queued request, not a rebuilt copy.
        let targets = await records.writeRecords.map(\.writeTarget)
        #expect(!targets.isEmpty)
        #expect(targets.allSatisfy { $0 == input.target })
    }

    @Test("a released continuation keeps its linkage")
    func releasesContinuationWithLinkage() async throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let startedAt = Date(timeIntervalSince1970: 100)
        let input = makeWriteInput()
        let source = makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(10),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: input.target,
                workItems: [failed],
                includesSyncTransition: false
            )
        )
        let holdID = UUID()
        let request = try RunRequest.continuation(of: source, input: input)
        let records = RunRecordSpy()
        let orchestrator = makeOrchestrator(
            persistRunRecord: { await records.append($0) },
            currentDecisionTarget: { _ in input.target }
        )
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(request)
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        guard case .released = outcome else {
            Issue.record("Expected the continuation to be resubmitted, got \(outcome)")
            return
        }
        let linkage = await records.writeRecords.map(\.continuesRunID)
        #expect(!linkage.isEmpty)
        #expect(linkage.allSatisfy { $0 == source.runID })
    }

    @Test("a discard during freshness verification wins over the release")
    func discardWinsOverInFlightRelease() async {
        let holdID = UUID()
        let input = makeWriteInput()
        let gate = ConsentGate()
        let records = RunRecordSpy()
        let orchestrator = makeOrchestrator(
            persistRunRecord: { await records.append($0) },
            currentDecisionTarget: { _ in
                await gate.enter()
                return input.target
            }
        )
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))
        let release = Task { await orchestrator.releaseQueuedWrite() }
        await gate.waitUntilEntered()

        await orchestrator.discardQueuedWrite()
        await gate.open()

        #expect(await release.value == .empty)
        #expect(await records.writeRecords.isEmpty)
    }

    @Test("a write retained behind a recoverable run keeps the shipped response")
    func retainsBehindRecoverableRun() async {
        let startedAt = Date(timeIntervalSince1970: 100)
        let interrupted = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [makeWorkItem(state: .attempted)],
                includesSyncTransition: false
            )
        )
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecovery(interrupted)
        let request = RunRequest.manualWrite(input: makeWriteInput())

        let result = await orchestrator.submit(request)

        guard case .recoverable = result else {
            Issue.record("Expected the recoverable run to keep blocking writes, got \(result)")
            return
        }
        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
    }

    @Test("an equal-revision resubmission of the same plan wins the slot")
    func equalRevisionResubmissionWins() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let planID = FixPlanID()
        let first = RunRequest.manualWrite(input: makeWriteInput(planID: planID))
        let second = RunRequest.manualWrite(input: makeWriteInput(planID: planID))
        _ = await orchestrator.submit(first)

        _ = await orchestrator.submit(second)

        #expect(await orchestrator.queuedWriteRequest()?.id == second.id)
    }

    @Test("stale consent clears the slot without writing")
    func rejectsStaleQueuedWrite() async {
        let holdID = UUID()
        let input = makeWriteInput()
        let staleTarget = FixPlanWriteTarget(
            planID: input.target.planID,
            planRevision: input.target.planRevision.advanced(),
            decisionRevision: input.target.decisionRevision
        )
        let records = RunRecordSpy()
        let orchestrator = makeOrchestrator(
            persistRunRecord: { await records.append($0) },
            currentDecisionTarget: { _ in staleTarget }
        )
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .stale)
        #expect(await orchestrator.queuedWriteRequest() == nil)
        #expect(await records.writeRecords.isEmpty)
    }

    @Test("a changed decision revision alone is stale")
    func rejectsChangedDecisionRevision() async {
        let holdID = UUID()
        let input = makeWriteInput()
        let reviewedTarget = FixPlanWriteTarget(
            planID: input.target.planID,
            planRevision: input.target.planRevision,
            decisionRevision: input.target.decisionRevision.advanced()
        )
        let orchestrator = makeOrchestrator(currentDecisionTarget: { _ in reviewedTarget })
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .stale)
        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("a missing consent source refuses the write but keeps the slot")
    func failsClosedWithoutConsentSource() async {
        let holdID = UUID()
        let request = RunRequest.manualWrite(input: makeWriteInput())
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(request)
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .unverifiable(.sourceMissing))
        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
    }

    @Test("a plan without a current decision keeps the slot")
    func keepsSlotWithoutCurrentDecision() async {
        let holdID = UUID()
        let request = RunRequest.manualWrite(input: makeWriteInput())
        let orchestrator = makeOrchestrator(currentDecisionTarget: { _ in nil })
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(request)
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .unverifiable(.noCurrentDecision))
        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
    }

    @Test("an empty slot reports nothing to release")
    func reportsEmptySlot() async {
        let orchestrator = makeOrchestrator()

        #expect(await orchestrator.releaseQueuedWrite() == .empty)
    }

    @Test("clearing the hold never releases the queued write by itself")
    func clearanceDoesNotAutoRelease() async {
        let holdID = UUID()
        let request = RunRequest.manualWrite(input: makeWriteInput())
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(request)

        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
        #expect(await orchestrator.activeLifecycle() == nil)
    }

    @Test("admitting a second hold keeps the queued write")
    func secondHoldKeepsQueuedWrite() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let request = RunRequest.manualWrite(input: makeWriteInput())
        _ = await orchestrator.submit(request)

        await orchestrator.restoreRecoveryHold(id: UUID())

        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
    }

    @Test("a continuation request queues with its linkage intact")
    func queuesContinuationRequest() async throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let startedAt = Date(timeIntervalSince1970: 100)
        let input = makeWriteInput()
        let source = makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(10),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: input.target,
                workItems: [failed],
                includesSyncTransition: false
            )
        )
        let request = try RunRequest.continuation(of: source, input: input)
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())

        _ = await orchestrator.submit(request)

        let queued = try #require(await orchestrator.queuedWriteRequest())
        #expect(queued.continuesRunID == source.runID)
        #expect(queued.trigger == .recovery)
    }

    @Test("a fresh orchestrator starts with an empty slot")
    func startsWithEmptySlot() async {
        let orchestrator = makeOrchestrator()

        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    private func makeOrchestrator(
        synchronizeLibrary: @escaping @Sendable () async throws -> SyncResult = { SyncResult() },
        persistRunRecord: @escaping @Sendable (RunRecord) async throws -> Void = { _ in },
        currentDecisionTarget: (@Sendable (FixPlanID) async -> FixPlanWriteTarget?)? = nil
    ) -> RunOrchestrator {
        RunOrchestrator(dependencies: .init(
            synchronizeLibrary: synchronizeLibrary,
            persistRunRecord: persistRunRecord,
            currentDecisionTarget: currentDecisionTarget
        ))
    }

    private actor RunRecordSpy {
        private var records: [RunRecord] = []

        var writeRecords: [RunRecord] {
            records.filter { $0.intent == .writeFixes }
        }

        func append(_ record: RunRecord) {
            records.append(record)
        }
    }

    @Test("in-flight write plans cover the queued slot")
    func inFlightPlansCoverQueuedSlot() async {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let planID = FixPlanID()
        _ = await orchestrator.submit(RunRequest.manualWrite(input: makeWriteInput(planID: planID)))

        #expect(await orchestrator.inFlightWritePlanIDs() == [planID])
    }

    @Test("a write parked behind an active run stays in the in-flight plans")
    func inFlightPlansCoverParkedWrites() async {
        let gate = ConsentGate()
        let orchestrator = makeOrchestrator(synchronizeLibrary: {
            await gate.enter()
            return SyncResult()
        })
        async let observation = orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        await gate.waitUntilEntered()
        let planID = FixPlanID()
        let result = await orchestrator.submit(
            RunRequest.manualWrite(input: makeWriteInput(planID: planID))
        )

        // The parked plan is referenced by no persisted record yet; retention
        // must still see it (the exact hole behind the wave-1 F1 finding).
        #expect(await orchestrator.inFlightWritePlanIDs() == [planID])
        guard case .queued = result else {
            Issue.record("Expected the write to park behind the active run, got \(result)")
            await gate.open()
            _ = await observation
            return
        }
        await gate.open()
        _ = await observation
    }

    @Test("in-flight write plans are empty without write requests")
    func inFlightPlansEmptyWhenIdle() async {
        let orchestrator = makeOrchestrator()

        #expect(await orchestrator.inFlightWritePlanIDs().isEmpty)
    }

    /// Pauses the consent lookup so tests can interleave actor calls
    /// deterministically while a release is suspended mid-verification.
    private actor ConsentGate {
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            entered = true
            for waiter in enteredWaiters {
                waiter.resume()
            }
            enteredWaiters = []
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitUntilEntered() async {
            if entered {
                return
            }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func open() {
            for waiter in openWaiters {
                waiter.resume()
            }
            openWaiters = []
        }
    }

    private func makeWriteInput(
        planID: FixPlanID = FixPlanID(),
        planRevision: FixPlanRevision = .initial
    ) -> FixPlanWriteInput {
        let capturedAt = Date(timeIntervalSince1970: 200)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "queued-write-test"
        )
        return FixPlanWriteInput(
            target: FixPlanWriteTarget(
                planID: planID,
                planRevision: planRevision,
                decisionRevision: .initial
            ),
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
