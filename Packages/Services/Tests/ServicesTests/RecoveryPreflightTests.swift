import Foundation
import Services
import Testing

@Suite("RecoveryPreflight")
struct RecoveryPreflightTests {
    @Test("missing record resolves recovery")
    func missingResolves() async {
        let runID = RunID()
        let service = RecoveryPreflightService(store: RunRecordStoreProbe())

        let outcome = await service.run(for: runID)

        #expect(outcome == .resolved(runID: runID, reason: .recordMissing))
    }

    @Test("terminal record resolves recovery")
    func terminalResolves() async {
        let runID = RunID()
        let service = RecoveryPreflightService(store: RunRecordStoreProbe(record: makeRecord(
            runID: runID,
            state: .completedNoOp,
            finishedAt: Date(timeIntervalSince1970: 120)
        )))

        let outcome = await service.run(for: runID)

        #expect(outcome == .resolved(runID: runID, reason: .alreadyFinished))
    }

    @Test("open read-only records are inspectable")
    func readOnlyInspectable() async {
        let runID = RunID()
        for state in [
            RunLifecycleState.created,
            .queued,
            .syncingLibrary,
            .analyzingDelta,
            .planningFixes,
            .awaitingReview,
        ] {
            let service = RecoveryPreflightService(store: RunRecordStoreProbe(record: makeRecord(
                runID: runID,
                state: state,
                finishedAt: nil
            )))

            let outcome = await service.run(for: runID)

            #expect(outcome == .inspectable(runID: runID, state: state))
        }
    }

    @Test("reporting classification follows run intent")
    func reportingFollowsIntent() async {
        let runID = RunID()
        let writeService = RecoveryPreflightService(store: RunRecordStoreProbe(record: makeRecord(
            runID: runID,
            state: .reporting,
            finishedAt: nil,
            intent: .writeFixes
        )))
        let readService = RecoveryPreflightService(store: RunRecordStoreProbe(record: makeRecord(
            runID: runID,
            state: .reporting,
            finishedAt: nil,
            intent: .observeLibrary
        )))

        #expect(await writeService.run(for: runID) == .needsAttention(
            runID: runID,
            reason: .writeAdjacentState(.reporting)
        ))
        #expect(await readService.run(for: runID) == .inspectable(runID: runID, state: .reporting))
    }

    @Test("open write-adjacent records need attention")
    func writeAdjacentReview() async {
        let runID = RunID()
        for state in [RunLifecycleState.writing, .verifying] {
            let service = RecoveryPreflightService(store: RunRecordStoreProbe(record: makeRecord(
                runID: runID,
                state: state,
                finishedAt: nil
            )))

            let outcome = await service.run(for: runID)

            #expect(outcome == .needsAttention(runID: runID, reason: .writeAdjacentState(state)))
        }
    }

    @Test("open unresolved recovery records need attention")
    func unresolvedNeedsAttention() async {
        let runID = RunID()
        for state in [RunLifecycleState.blocked, .recoverable, .recovering] {
            let service = RecoveryPreflightService(store: RunRecordStoreProbe(record: makeRecord(
                runID: runID,
                state: state,
                finishedAt: nil
            )))

            let outcome = await service.run(for: runID)

            #expect(outcome == .needsAttention(runID: runID, reason: .unresolvedState(state)))
        }
    }

    @Test("store failure blocks recovery")
    func storeFailureBlocks() async {
        let runID = RunID()
        let service = RecoveryPreflightService(store: RunRecordStoreProbe(error: ProbeError()))

        let outcome = await service.run(for: runID)

        #expect(outcome == .blocked(runID: runID, reason: .storeUnavailable))
    }
}

private actor RunRecordStoreProbe: RunRecordStore {
    private let record: RunRecord?
    private let error: Error?

    init(record: RunRecord? = nil, error: Error? = nil) {
        self.record = record
        self.error = error
    }

    func upsert(_: RunRecord) async throws {
        // This probe only exercises read paths; writes are intentionally ignored.
    }

    func loadAll() async throws -> [RunRecord] {
        []
    }

    func record(for _: RunID) async throws -> RunRecord? {
        if let error {
            throw error
        }
        return record
    }

    func prune(keepingLatest _: Int) async throws -> Int {
        0
    }

    func recoveryRecords() async throws -> RunReportPage {
        RunReportPage(records: record.map { [$0] } ?? [], skippedCorruptedCount: 0)
    }

    func closeCorruptedRun(_: RunID, at _: Date) async throws -> Bool {
        false
    }

    func claimRecovery(for _: RunID, id _: UUID, at _: Date) async throws -> UUID? {
        nil
    }

    func reports(matching _: RunReportQuery) async throws -> RunReportPage {
        RunReportPage(records: record.map { [$0] } ?? [], skippedCorruptedCount: 0)
    }
}

private func makeRecord(
    runID: RunID,
    state: RunLifecycleState,
    finishedAt: Date?,
    intent: RunIntent = .observeLibrary
) -> RunRecord {
    let startedAt = Date(timeIntervalSince1970: 100)
    var transitions = [
        RunLifecycleTransition(state: .created, timestamp: startedAt),
    ]
    if state != .created {
        transitions.append(RunLifecycleTransition(state: state, timestamp: startedAt.addingTimeInterval(1)))
    }

    return RunRecord(
        runID: runID,
        requestID: RunRequestID(),
        trigger: .manualCheck,
        intent: intent,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "test"
        ),
        transitions: transitions,
        syncSummary: nil,
        failureMessage: nil,
        startedAt: startedAt,
        finishedAt: finishedAt
    )
}

private struct ProbeError: Error {}
