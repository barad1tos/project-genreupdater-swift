import Core
import Foundation
import Testing
@testable import Services

@Suite("Run continuation requests")
struct RunContinuationTests {
    @Test("a closed write run with failed work produces a linked recovery request")
    func createsLinkedRequest() throws {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeClosedWriteRecord(workItems: [failed])
        let input = makeWriteInput()

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

    @Test("a fully landed source run has nothing to continue")
    func rejectsNothingToContinue() throws {
        let written = makeWorkItem(state: .outcome(.written))
        let dismissed = makeWorkItem(state: .outcome(.dismissed))
        let record = makeClosedWriteRecord(workItems: [written, dismissed])

        #expect(throws: RunContinuationError.nothingToContinue) {
            try RunRequest.continuation(of: record, input: makeWriteInput())
        }
    }

    private func makeClosedWriteRecord(
        workItems: [RunWorkItem],
        finished: Bool = true
    ) -> RunRecord {
        let startedAt = Date(timeIntervalSince1970: 100)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: finished ? startedAt.addingTimeInterval(10) : nil,
            state: finished ? .cancelled : .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: workItems,
                includesSyncTransition: false
            )
        )
    }

    private func makeWriteInput() -> FixPlanWriteInput {
        let capturedAt = Date(timeIntervalSince1970: 200)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "continuation-test"
        )
        return FixPlanWriteInput(
            target: writeTarget(),
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
