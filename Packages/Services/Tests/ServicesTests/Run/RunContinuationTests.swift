import Core
import Foundation
import Testing
@testable import Services

@Suite("Run continuation requests")
struct RunContinuationTests {
    @Test("a closed write run with failed work produces a linked recovery request")
    func createsLinkedRequest() throws {
        let target = writeTarget()
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed], target: target)
        let input = makeWriteInput(target: target)

        let request = try RunRequest.continuation(of: record, input: input)

        #expect(request.trigger == .recovery)
        #expect(request.intent == .writeFixes)
        #expect(request.continuesRunID == record.runID)
        #expect(request.writeTarget == input.target)
    }

    @Test("an open source run cannot be continued")
    func rejectsOpenSource() throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed], finished: false)

        #expect(throws: RunContinuationError.sourceRunStillOpen) {
            try RunRequest.continuation(of: record, input: makeWriteInput())
        }
    }

    @Test("a non-write source run cannot be continued")
    func rejectsNonWriteSource() throws {
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completed,
            syncSummary: nil
        )

        #expect(throws: RunContinuationError.sourceRunNotWrite) {
            try RunRequest.continuation(of: record, input: makeWriteInput())
        }
    }

    @Test("continuation input must arrive fully prepared")
    func rejectsUnpreparedInput() throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed])
        let capturedAt = Date(timeIntervalSince1970: 200)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "continuation-test"
        )
        let terminalInput = FixPlanWriteInput(
            target: writeTarget(),
            scope: scope,
            admission: processingAdmission(scope: scope),
            configuration: makeRunConfiguration(
                scopeID: scope.id,
                capturedAt: capturedAt,
                writeAuthority: .reviewedPlan
            ),
            workItems: record.continuableWork
        )

        #expect(throws: RunContinuationError.inputWorkNotPrepared) {
            try RunRequest.continuation(of: record, input: terminalInput)
        }
    }

    @Test("linkage flows from request through snapshot into the record")
    func propagatesLinkageThroughLifecycle() throws {
        let target = writeTarget()
        let failed = makeWorkItem(state: .outcome(.failed))
        let source = makeClosedWriteRecord(workItems: [failed], target: target)
        let input = makeWriteInput(target: target)
        let request = try RunRequest.continuation(of: source, input: input)
        let snapshot = RunLifecycleSnapshot(
            request: request,
            scope: input.scope,
            startedAt: Date(timeIntervalSince1970: 300),
            phase: .active(.writing)
        )

        let record = RunRecord(
            lifecycle: snapshot,
            transitions: [RunLifecycleTransition(state: .writing, timestamp: snapshot.startedAt)],
            syncSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )

        #expect(snapshot.continuesRunID == source.runID)
        #expect(record.continuesRunID == source.runID)
        #expect(record.trigger == .recovery)
    }

    @Test("a fully landed source run has nothing to continue")
    func rejectsNothingToContinue() throws {
        let written = makeWorkItem(state: .outcome(.written))
        let dismissed = makeWorkItem(state: .outcome(.dismissed))
        let record = makeClosedWriteRecord(workItems: [written, dismissed])

        #expect(throws: RunContinuationError.nothingToContinue) {
            try RunRequest.continuation(of: record, input: makeWriteInput())
        }
    }

    @Test("a plan other than the one the source run executed cannot continue it")
    func rejectsForeignPlan() throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed], target: writeTarget())

        #expect(throws: RunContinuationError.inputPlanMismatch) {
            try RunRequest.continuation(of: record, input: makeWriteInput(target: writeTarget()))
        }
    }

    @Test("advanced revisions of the same plan may still continue the run")
    func acceptsAdvancedRevisionsOfSamePlan() throws {
        let executed = writeTarget()
        let advanced = FixPlanWriteTarget(
            planID: executed.planID,
            planRevision: FixPlanRevision(executed.planRevision.value + 1),
            decisionRevision: ReviewDecisionRevision(executed.decisionRevision.value + 1)
        )
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed], target: executed)

        let request = try RunRequest.continuation(of: record, input: makeWriteInput(target: advanced))

        #expect(request.continuesRunID == record.runID)
    }

    @Test("a source run without a recorded plan fails closed")
    func rejectsUnverifiableSourcePlan() throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed], target: nil)

        #expect(throws: RunContinuationError.inputPlanMismatch) {
            try RunRequest.continuation(of: record, input: makeWriteInput())
        }
    }

    private func makeClosedWriteRecord(
        workItems: [RunWorkItem],
        finished: Bool = true,
        target: FixPlanWriteTarget? = nil
    ) -> RunRecord {
        let startedAt = Date(timeIntervalSince1970: 100)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: finished ? startedAt.addingTimeInterval(10) : nil,
            state: finished ? .cancelled : .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: target,
                workItems: workItems,
                includesSyncTransition: false
            )
        )
    }

    private func makeWriteInput(target: FixPlanWriteTarget? = nil) -> FixPlanWriteInput {
        let capturedAt = Date(timeIntervalSince1970: 200)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "continuation-test"
        )
        return FixPlanWriteInput(
            target: target ?? writeTarget(),
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
