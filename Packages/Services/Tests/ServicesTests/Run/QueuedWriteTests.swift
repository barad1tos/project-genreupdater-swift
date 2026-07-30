import Core
import Foundation
import Testing
@testable import Services

@Suite("Queued writes behind recovery holds")
struct QueuedWriteTests {
    @Test("a write submitted under a hold is retained, not executed")
    func queuesWriteUnderHold() async throws {
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
    func keepsFirstQueuedWrite() async throws {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let first = RunRequest.manualWrite(input: makeWriteInput())
        let second = RunRequest.manualWrite(input: makeWriteInput())
        _ = await orchestrator.submit(first)

        _ = await orchestrator.submit(second)

        #expect(await orchestrator.queuedWriteRequest()?.id == first.id)
    }

    @Test("a newer revision of the same plan supersedes the queued request")
    func replacesWithNewerRevision() async throws {
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
    func submitsNormallyWithoutHold() async throws {
        let orchestrator = makeOrchestrator()
        let request = RunRequest.manualWrite(input: makeWriteInput())

        let result = await orchestrator.submit(request)

        if case .recoveryRequired = result {
            Issue.record("A write without a hold must not be blocked")
        }
        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("discarding empties the slot")
    func discardsQueuedWrite() async throws {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        _ = await orchestrator.submit(RunRequest.manualWrite(input: makeWriteInput()))

        await orchestrator.discardQueuedWrite()

        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("release is refused while the hold is still engaged")
    func refusesReleaseUnderHold() async throws {
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: UUID())
        let request = RunRequest.manualWrite(input: makeWriteInput())
        _ = await orchestrator.submit(request)

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .blocked)
        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
    }

    @Test("release with current consent resubmits the queued write")
    func releasesFreshQueuedWrite() async throws {
        let holdID = UUID()
        let input = makeWriteInput()
        let orchestrator = makeOrchestrator(currentDecisionTarget: { planID in
            planID == input.target.planID ? input.target : nil
        })
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        guard case .released = outcome else {
            Issue.record("Expected the queued write to be resubmitted, got \(outcome)")
            return
        }
        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("stale consent clears the slot without writing")
    func rejectsStaleQueuedWrite() async throws {
        let holdID = UUID()
        let input = makeWriteInput()
        let staleTarget = FixPlanWriteTarget(
            planID: input.target.planID,
            planRevision: input.target.planRevision.advanced(),
            decisionRevision: input.target.decisionRevision
        )
        let orchestrator = makeOrchestrator(currentDecisionTarget: { _ in staleTarget })
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: input))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .stale)
        #expect(await orchestrator.queuedWriteRequest() == nil)
        #expect(await orchestrator.activeLifecycle() == nil)
    }

    @Test("unverifiable consent fails closed")
    func failsClosedWithoutConsentSource() async throws {
        let holdID = UUID()
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(RunRequest.manualWrite(input: makeWriteInput()))
        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        let outcome = await orchestrator.releaseQueuedWrite()

        #expect(outcome == .stale)
        #expect(await orchestrator.queuedWriteRequest() == nil)
    }

    @Test("an empty slot reports nothing to release")
    func reportsEmptySlot() async throws {
        let orchestrator = makeOrchestrator()

        #expect(await orchestrator.releaseQueuedWrite() == .empty)
    }

    @Test("clearing the hold never releases the queued write by itself")
    func clearanceDoesNotAutoRelease() async throws {
        let holdID = UUID()
        let request = RunRequest.manualWrite(input: makeWriteInput())
        let orchestrator = makeOrchestrator()
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(request)

        _ = await orchestrator.resolveRecovery(id: holdID, runID: nil, at: Date(timeIntervalSince1970: 300))

        #expect(await orchestrator.queuedWriteRequest()?.id == request.id)
        #expect(await orchestrator.activeLifecycle() == nil)
    }

    private func makeOrchestrator(
        currentDecisionTarget: (@Sendable (FixPlanID) async -> FixPlanWriteTarget?)? = nil
    ) -> RunOrchestrator {
        RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { _ in },
            currentDecisionTarget: currentDecisionTarget
        ))
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
            configuration: makeRunConfiguration(
                scopeID: scope.id,
                capturedAt: capturedAt,
                writeAuthority: .reviewedPlan
            ),
            workItems: [makeWorkItem(state: .prepared)]
        )
    }
}
