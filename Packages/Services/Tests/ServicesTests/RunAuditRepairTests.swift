import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run audit repair")
struct RunAuditRepairTests {
    @Test("Terminal read audit repairs its missing finish")
    func repairsReadAudit() async throws {
        let fixture = try makeFixture(intent: .observeLibrary)

        let page = try await fixture.store.recoveryRecords()

        #expect(page.closableRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: fixture.finishedAt
        ))
        let audit = try #require(await fixture.store.record(for: RunID(rawValue: fixture.runID)))
        #expect(audit.state == .completed)
        #expect(audit.transitions == fixture.transitions)
        #expect(audit.finishedAt == fixture.finishedAt)
    }

    @Test("Terminal write audit repairs only after recovery")
    func repairsWriteAudit() async throws {
        let fixture = try makeFixture(intent: .writeFixes)

        let page = try await fixture.store.recoveryRecords()

        #expect(page.recoveryRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: fixture.finishedAt
        ) == false)
        #expect(try await fixture.store.closeCorruptedRun(
            RunID(rawValue: fixture.runID),
            at: fixture.finishedAt
        ))
        let audit = try #require(await fixture.store.record(for: RunID(rawValue: fixture.runID)))
        #expect(audit.state == .completed)
        #expect(audit.transitions == fixture.transitions)
        #expect(audit.finishedAt == fixture.finishedAt)
    }

    @Test("Terminal write audit closes after a resolved block")
    func repairsBlockedAudit() async throws {
        let fixture = try makeFixture(
            intent: .writeFixes,
            terminalState: .cancelled,
            includesBlockedStop: true
        )

        let page = try await fixture.store.recoveryRecords()

        #expect(page.recoveryRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(try await fixture.store.closeCorruptedRun(
            RunID(rawValue: fixture.runID),
            at: fixture.finishedAt
        ))
        let audit = try #require(await fixture.store.record(for: RunID(rawValue: fixture.runID)))
        #expect(audit.state == .cancelled)
        #expect(audit.transitions == fixture.transitions)
        #expect(audit.finishedAt == fixture.finishedAt)
    }

    @Test("Finished terminal audit repairs reversed timestamps")
    func repairsFinishedTimeline() async throws {
        let fixture = try makeFixture(
            intent: .observeLibrary,
            storedFinish: Date(timeIntervalSince1970: 103),
            reversesTime: true
        )

        let page = try await fixture.store.recoveryRecords()

        #expect(page.closableRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: fixture.finishedAt
        ))
        let audit = try #require(await fixture.store.record(for: RunID(rawValue: fixture.runID)))
        #expect(audit.state == .completed)
        #expect(audit.transitions.map(\.timestamp) == audit.transitions.map(\.timestamp).sorted())
        #expect(audit.finishedAt == fixture.finishedAt)
    }

    @Test("Finished write audit keeps its finish and retention")
    func repairsWriteTimeline() async throws {
        let storedFinish = Date(timeIntervalSince1970: 103)
        let fixture = try makeFixture(
            intent: .writeFixes,
            storedFinish: storedFinish,
            reversesTime: true
        )
        try await fixture.store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completed,
            syncSummary: nil
        ))

        let page = try await fixture.store.recoveryRecords()

        #expect(page.closableRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(try await fixture.store.prune(keepingLatest: 1) == 0)
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: Date(timeIntervalSince1970: 500)
        ))
        let audit = try #require(await fixture.store.record(for: RunID(rawValue: fixture.runID)))
        #expect(audit.state == .completed)
        #expect(audit.finishedAt == storedFinish)
    }

    @Test("Compound terminal corruption preserves its outcome")
    func holdsCompoundOutcome() async throws {
        let fixture = try makeFixture(
            intent: .observeLibrary,
            storedFinish: Date(timeIntervalSince1970: 103),
            reversesTime: true,
            corruption: AuditCorruption(corruptsScope: true)
        )

        let page = try await fixture.store.recoveryRecords()

        #expect(page.corruptedRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(page.attentionRunIDs.isEmpty)
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.closableRunIDs.isEmpty)
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: Date(timeIntervalSince1970: 500)
        ) == false)
        let rows = try ModelContext(fixture.container).fetch(FetchDescriptor<PersistedRunRecord>())
        let row = try #require(rows.first { $0.runID == fixture.runID })
        #expect(row.stateRaw == RunLifecycleState.completed.rawValue)
        try await fixture.store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completed,
            syncSummary: nil
        ))
        #expect(try await fixture.store.prune(keepingLatest: 1) == 1)
        let retainedRows = try ModelContext(fixture.container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(retainedRows.contains { $0.runID == fixture.runID } == false)
    }

    @Test("Header-only terminal corruption preserves its outcome")
    func holdsHeaderOutcome() async throws {
        let fixture = try makeFixture(
            intent: .observeLibrary,
            storedFinish: Date(timeIntervalSince1970: 103),
            reversesTime: true,
            corruption: AuditCorruption(
                corruptsScope: true,
                omitsTerminalTransition: true
            )
        )

        let page = try await fixture.store.recoveryRecords()

        #expect(page.corruptedRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(page.unresolvedRunIDs.isEmpty)
        #expect(page.closableRunIDs.isEmpty)
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: Date(timeIntervalSince1970: 500)
        ) == false)
        let rows = try ModelContext(fixture.container).fetch(FetchDescriptor<PersistedRunRecord>())
        let row = try #require(rows.first { $0.runID == fixture.runID })
        #expect(row.stateRaw == RunLifecycleState.completed.rawValue)
    }

    @Test("Finished audit with missing configuration requires attention")
    func holdsMissingConfiguration() async throws {
        try await assertUnsafeAudit(.missingConfiguration)
    }

    @Test("Finished audit with malformed write target requires attention")
    func holdsMalformedTarget() async throws {
        try await assertUnsafeAudit(.malformedWriteTarget)
    }

    @Test("Terminal outcome conflict requires attention")
    func holdsOutcomeConflict() async throws {
        let fixture = try makeFixture(
            intent: .writeFixes,
            storedFinish: Date(timeIntervalSince1970: 103),
            corruption: AuditCorruption(payloadState: .failed)
        )

        try await assertAttention(fixture)
    }

    @Test("Read-only outcome conflict stays diagnostic")
    func keepsReadConflictDiagnostic() async throws {
        let fixture = try makeFixture(
            intent: .observeLibrary,
            storedFinish: Date(timeIntervalSince1970: 103),
            corruption: AuditCorruption(payloadState: .failed)
        )

        let page = try await fixture.store.recoveryRecords()

        #expect(page.corruptedRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(page.unresolvedRunIDs.isEmpty)
        #expect(page.closableRunIDs.isEmpty)
    }

    @Test("Terminal write tail requires attention", arguments: [false, true])
    func holdsWriteTail(reversesTime: Bool) async throws {
        let fixture = try makeFixture(
            intent: .writeFixes,
            storedFinish: Date(timeIntervalSince1970: 103),
            reversesTime: reversesTime,
            corruption: AuditCorruption(payloadState: .writing)
        )

        try await assertAttention(fixture)
    }

    @Test("Terminal reporting tail requires attention", arguments: [false, true])
    func holdsReportingTail(reversesTime: Bool) async throws {
        let fixture = try makeFixture(
            intent: .writeFixes,
            storedFinish: Date(timeIntervalSince1970: 103),
            reversesTime: reversesTime,
            corruption: AuditCorruption(payloadState: .reporting)
        )

        try await assertAttention(fixture)
    }

    @Test("Terminal write header rejects an early audit tail")
    func holdsEarlyWriteTail() async throws {
        let fixture = try makeFixture(
            intent: .writeFixes,
            storedFinish: Date(timeIntervalSince1970: 103),
            corruption: AuditCorruption(payloadState: .created)
        )

        try await assertAttention(fixture)
    }

    @Test("Missing write audit tail requires attention")
    func holdsMissingWriteAudit() async throws {
        for fault in [AuditPayloadFault.malformedPayload, .emptyTransitions] {
            try await assertUnsafeAudit(fault)
        }
    }

    @Test("Mismatched configuration scope requires attention")
    func holdsScopeMismatch() async throws {
        try await assertUnsafeAudit(.mismatchedScope)
    }

    private func makeFixture(
        intent: RunIntent,
        storedFinish: Date? = nil,
        reversesTime: Bool = false,
        terminalState: RunLifecycleState = .completed,
        includesBlockedStop: Bool = false,
        corruption: AuditCorruption = AuditCorruption()
    ) throws -> RepairFixture {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = startedAt.addingTimeInterval(2)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let transitions = makeTransitions(
            startedAt: startedAt,
            reversesTime: reversesTime,
            terminalState: terminalState,
            includesBlockedStop: includesBlockedStop,
            corruption: corruption
        )
        let configScopeID = corruption.payloadFault == .mismatchedScope ? UUID() : scope.id
        let configuration = makeRunConfiguration(
            scopeID: configScopeID,
            capturedAt: startedAt,
            writeAuthority: intent == .writeFixes ? .reviewedPlan : .readOnly
        )
        let transitionsData = try makePayloadData(
            transitions: transitions,
            configuration: configuration,
            fault: corruption.payloadFault
        )
        try insertRunRow(
            runID: runID,
            transitionsData: transitionsData,
            input: RunRowInput(
                scopeData: corruption.corruptsScope ? Data([0xDE, 0xAD, 0xBE, 0xEF]) : JSONEncoder().encode(scope),
                intent: intent,
                state: terminalState,
                startedAt: startedAt,
                finishedAt: storedFinish
            ),
            into: container
        )
        return RepairFixture(
            runID: runID,
            finishedAt: max(finishedAt, storedFinish ?? finishedAt),
            transitions: reversesTime ? transitions.map {
                RunLifecycleTransition(state: $0.state, timestamp: startedAt.addingTimeInterval(1))
            } : transitions,
            container: container,
            store: RunRecordDataStore(modelContainer: container)
        )
    }

    private func makeTransitions(
        startedAt: Date,
        reversesTime: Bool,
        terminalState: RunLifecycleState,
        includesBlockedStop: Bool,
        corruption: AuditCorruption
    ) -> [RunLifecycleTransition] {
        var transitions = [
            RunLifecycleTransition(
                state: .created,
                timestamp: startedAt.addingTimeInterval(reversesTime ? 1 : 0)
            ),
        ]
        if includesBlockedStop {
            transitions.append(RunLifecycleTransition(state: .blocked, timestamp: startedAt.addingTimeInterval(1)))
        }
        if corruption.omitsTerminalTransition {
            transitions.append(RunLifecycleTransition(state: .reporting, timestamp: startedAt))
            return transitions
        }
        var terminalOffset: TimeInterval = includesBlockedStop ? 2 : 1
        if reversesTime {
            terminalOffset = 0
        }
        transitions.append(RunLifecycleTransition(
            state: corruption.payloadState ?? terminalState,
            timestamp: startedAt.addingTimeInterval(terminalOffset)
        ))
        return transitions
    }

    private func assertUnsafeAudit(_ fault: AuditPayloadFault) async throws {
        let fixture = try makeFixture(
            intent: .writeFixes,
            storedFinish: Date(timeIntervalSince1970: 103),
            corruption: AuditCorruption(payloadFault: fault)
        )

        try await assertAttention(fixture)
    }

    private func assertAttention(_ fixture: RepairFixture) async throws {
        let page = try await fixture.store.recoveryRecords()

        #expect(page.attentionRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(page.unresolvedRunIDs == [RunID(rawValue: fixture.runID)])
        #expect(page.closableRunIDs.isEmpty)
        #expect(try await fixture.store.closeReadOnlyCorruption(
            RunID(rawValue: fixture.runID),
            at: Date(timeIntervalSince1970: 500)
        ) == false)
    }

    private func makePayloadData(
        transitions: [RunLifecycleTransition],
        configuration: RunConfig,
        fault: AuditPayloadFault?
    ) throws -> Data {
        switch fault {
        case .malformedPayload:
            Data([0xDE, 0xAD, 0xBE, 0xEF])
        case .emptyTransitions:
            try JSONEncoder().encode(VersionedPayload(
                transitions: [],
                configuration: configuration
            ))
        case .missingConfiguration:
            try JSONEncoder().encode(MissingConfigPayload(transitions: transitions))
        case .malformedWriteTarget:
            try JSONEncoder().encode(MalformedWriteTargetPayload(
                transitions: transitions,
                configuration: configuration
            ))
        case .mismatchedScope, nil:
            try JSONEncoder().encode(VersionedPayload(
                transitions: transitions,
                configuration: configuration
            ))
        }
    }
}

private enum AuditPayloadFault: Equatable, Sendable {
    case malformedPayload
    case emptyTransitions
    case missingConfiguration
    case malformedWriteTarget
    case mismatchedScope
}

private struct AuditCorruption {
    var corruptsScope = false
    var payloadFault: AuditPayloadFault?
    var payloadState: RunLifecycleState?
    var omitsTerminalTransition = false
}

private struct RepairFixture {
    let runID: UUID
    let finishedAt: Date
    let transitions: [RunLifecycleTransition]
    let container: ModelContainer
    let store: RunRecordDataStore
}
