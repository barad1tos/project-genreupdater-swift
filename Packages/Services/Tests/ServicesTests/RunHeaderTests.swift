import Foundation
import Testing
@testable import Services

@Suite("Run header persistence")
struct RunHeaderTests {
    @Test("upsert preserves the complete configured scope snapshot")
    func rejectsConfiguredScope() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let changedScope = ProcessingScopeSnapshot(
            id: initial.scope.id,
            createdAt: initial.scope.createdAt,
            source: initial.scope.source,
            normalizedTestArtists: initial.scope.normalizedTestArtists,
            matchingRule: initial.scope.matchingRule,
            knownTrackCount: initial.scope.knownTrackCount,
            fingerprint: initial.scope.fingerprint,
            reason: "changed"
        )
        let replacement = replacing(initial, scope: changedScope, configuration: initial.configuration)
        try await store.upsert(initial)

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(replacement)
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert preserves the complete legacy scope snapshot")
    func rejectsLegacyScope() async throws {
        let store = try makeRunStore()
        let configured = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let initial = replacing(configured, scope: configured.scope, configuration: nil)
        let changedScope = ProcessingScopeSnapshot(
            id: initial.scope.id,
            createdAt: initial.scope.createdAt,
            source: initial.scope.source,
            normalizedTestArtists: ["Boards of Canada"],
            matchingRule: initial.scope.matchingRule,
            knownTrackCount: initial.scope.knownTrackCount,
            fingerprint: initial.scope.fingerprint,
            reason: initial.scope.reason
        )
        let replacement = replacing(initial, scope: changedScope, configuration: nil)
        try await store.upsert(initial)

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(replacement)
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert updates a legacy record when scope and nil configuration stay unchanged")
    func updatesLegacyRecord() async throws {
        let store = try makeRunStore()
        let configured = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let initial = replacing(configured, scope: configured.scope, configuration: nil)
        let finishedAt = Date(timeIntervalSince1970: 101)
        let final = RunRecord(
            runID: initial.runID,
            requestID: initial.requestID,
            trigger: initial.trigger,
            intent: initial.intent,
            scope: initial.scope,
            configuration: nil,
            transitions: initial.transitions + [
                RunLifecycleTransition(state: .completedNoOp, timestamp: finishedAt),
            ],
            syncSummary: initial.syncSummary,
            failureMessage: nil,
            startedAt: initial.startedAt,
            finishedAt: finishedAt
        )
        try await store.upsert(initial)

        try await store.upsert(final)

        #expect(try await store.record(for: initial.runID) == final)
    }

    @Test("upsert fails loudly instead of replacing an unreadable record")
    func rejectsUnreadableUpdate() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            input: RunRowInput(state: .syncingLibrary),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)
        let replacement = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            input: RunRecordInput(runID: RunID(rawValue: runID))
        )

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(replacement)
        }
        #expect(try await store.reports(matching: RunReportQuery()).corruptedRunIDs == [replacement.runID])
    }

    @Test("upsert preserves every immutable run header field")
    func rejectsHeaderReplacement() async throws {
        for field in ImmutableRunField.allCases {
            let store = try makeRunStore()
            let initial = makeRunRecord(
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: nil,
                state: .syncingLibrary,
                syncSummary: nil
            )
            try await store.upsert(initial)

            do {
                try await store.upsert(headerReplacement(for: initial, changing: field))
                Issue.record("Expected immutable field \(field.rawValue) to reject replacement")
            } catch let RunRecordPersistenceError.invalidField(name, runID) {
                #expect(name == field.rawValue)
                #expect(runID == initial.runID.rawValue)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(try await store.record(for: initial.runID) == initial)
        }
    }

    @Test("upsert cannot clear an existing recovery identifier")
    func preservesRecoveryID() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            input: RunRecordInput(intent: .writeFixes, recoveryID: UUID())
        )
        let replacement = RunRecord(
            runID: initial.runID,
            requestID: initial.requestID,
            trigger: initial.trigger,
            intent: initial.intent,
            scope: initial.scope,
            configuration: initial.configuration,
            writeTarget: initial.writeTarget,
            recoveryID: nil,
            transitions: initial.transitions,
            syncSummary: initial.syncSummary,
            writeSummary: initial.writeSummary,
            failureMessage: initial.failureMessage,
            startedAt: initial.startedAt,
            finishedAt: initial.finishedAt
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(replacement)
            Issue.record("Expected recovery identifier replacement to fail")
        } catch let RunRecordPersistenceError.invalidField(name, runID) {
            #expect(name == "recoveryID")
            #expect(runID == initial.runID.rawValue)
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert cannot roll transition history backward")
    func rejectsTransitionRollback() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .verifying,
            syncSummary: nil,
            input: RunRecordInput(intent: .writeFixes)
        )
        let stale = RunRecord(
            runID: initial.runID,
            requestID: initial.requestID,
            trigger: initial.trigger,
            intent: initial.intent,
            scope: initial.scope,
            configuration: initial.configuration,
            writeTarget: initial.writeTarget,
            recoveryID: initial.recoveryID,
            transitions: Array(initial.transitions.dropLast()),
            syncSummary: initial.syncSummary,
            writeSummary: initial.writeSummary,
            failureMessage: initial.failureMessage,
            startedAt: initial.startedAt,
            finishedAt: nil
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(stale)
            Issue.record("Expected stale transitions to be rejected")
        } catch let RunRecordPersistenceError.invalidField(name, _) {
            #expect(name == "transitions")
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert cannot reopen a terminal run")
    func rejectsTerminalReopen() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 102),
            state: .completed,
            syncSummary: nil
        )
        let reopened = RunRecord(
            runID: initial.runID,
            requestID: initial.requestID,
            trigger: initial.trigger,
            intent: initial.intent,
            scope: initial.scope,
            configuration: initial.configuration,
            writeTarget: initial.writeTarget,
            recoveryID: initial.recoveryID,
            transitions: initial.transitions,
            syncSummary: initial.syncSummary,
            writeSummary: initial.writeSummary,
            failureMessage: initial.failureMessage,
            startedAt: initial.startedAt,
            finishedAt: nil
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(reopened)
            Issue.record("Expected terminal run reopening to be rejected")
        } catch let RunRecordPersistenceError.invalidField(name, _) {
            #expect(name == "finishedAt")
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert cannot append transitions to a terminal run")
    func rejectsTerminalAppend() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 102),
            state: .completed,
            syncSummary: nil
        )
        let replacement = RunRecord(
            runID: initial.runID,
            requestID: initial.requestID,
            trigger: initial.trigger,
            intent: initial.intent,
            scope: initial.scope,
            configuration: initial.configuration,
            writeTarget: initial.writeTarget,
            recoveryID: initial.recoveryID,
            transitions: initial.transitions + [
                RunLifecycleTransition(state: .failed, timestamp: Date(timeIntervalSince1970: 103)),
            ],
            syncSummary: initial.syncSummary,
            writeSummary: initial.writeSummary,
            failureMessage: initial.failureMessage,
            startedAt: initial.startedAt,
            finishedAt: initial.finishedAt
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(replacement)
            Issue.record("Expected terminal transition append to be rejected")
        } catch let RunRecordPersistenceError.invalidField(name, _) {
            #expect(name == "transitions")
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert rejects inconsistent lifecycle completion")
    func rejectsInvalidFinishedAt() async throws {
        let store = try makeRunStore()
        let records = [
            makeRunRecord(
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101),
                state: .writing,
                syncSummary: nil
            ),
            makeRunRecord(
                startedAt: Date(timeIntervalSince1970: 200),
                finishedAt: nil,
                state: .completed,
                syncSummary: nil
            ),
            makeRunRecord(
                startedAt: Date(timeIntervalSince1970: 300),
                finishedAt: Date(timeIntervalSince1970: 301),
                state: .blocked,
                syncSummary: nil
            ),
        ]

        for record in records {
            do {
                try await store.upsert(record)
                Issue.record("Expected inconsistent lifecycle completion to be rejected")
            } catch let RunRecordPersistenceError.invalidField(name, _) {
                #expect(name == "finishedAt")
            }
            #expect(try await store.record(for: record.runID) == nil)
        }
    }

    @Test("upsert cannot rewrite a terminal audit")
    func rejectsTerminalMutation() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(intent: .writeFixes)
        )
        let replacements = [
            ("recoveryID", terminalReplacement(initial, recoveryID: UUID())),
            ("syncSummary", terminalReplacement(
                initial,
                syncSummary: ActivitySyncSummary(new: 1, modified: 0, identityChanged: 0, refreshed: 0, removed: 0)
            )),
            ("writeSummary", terminalReplacement(
                initial,
                writeSummary: RunWriteSummary(applied: 1, verifiedNoOp: 0, failed: 0)
            )),
            ("failureMessage", terminalReplacement(initial, failureMessage: "rewritten")),
        ]
        try await store.upsert(initial)

        for (field, replacement) in replacements {
            do {
                try await store.upsert(replacement)
                Issue.record("Expected terminal \(field) mutation to be rejected")
            } catch let RunRecordPersistenceError.invalidField(name, _) {
                #expect(name == field)
            }
            #expect(try await store.record(for: initial.runID) == initial)
        }
    }

    @Test("upsert rejects transitions after a terminal state")
    func rejectsTerminalHistory() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let base = makeRunRecord(
            startedAt: startedAt,
            finishedAt: Date(timeIntervalSince1970: 102),
            state: .cancelled,
            syncSummary: nil
        )
        let record = RunRecord(
            runID: base.runID,
            requestID: base.requestID,
            trigger: base.trigger,
            intent: base.intent,
            scope: base.scope,
            configuration: base.configuration,
            writeTarget: base.writeTarget,
            recoveryID: base.recoveryID,
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .completed, timestamp: startedAt.addingTimeInterval(1)),
                RunLifecycleTransition(state: .cancelled, timestamp: startedAt.addingTimeInterval(2)),
            ],
            syncSummary: base.syncSummary,
            writeSummary: base.writeSummary,
            failureMessage: base.failureMessage,
            startedAt: base.startedAt,
            finishedAt: base.finishedAt
        )

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(record)
        }
        #expect(try await store.record(for: record.runID) == nil)
    }

    private func headerReplacement(for record: RunRecord, changing field: ImmutableRunField) -> RunRecord {
        RunRecord(
            runID: record.runID,
            requestID: field == .requestID ? RunRequestID() : record.requestID,
            trigger: field == .trigger ? .recovery : record.trigger,
            intent: field == .intent ? .writeFixes : record.intent,
            scope: record.scope,
            configuration: record.configuration,
            writeTarget: field == .writeTarget
                ? FixPlanWriteTarget(
                    planID: FixPlanID(),
                    planRevision: .initial,
                    decisionRevision: .initial
                )
                : record.writeTarget,
            recoveryID: record.recoveryID,
            transitions: record.transitions,
            syncSummary: record.syncSummary,
            writeSummary: record.writeSummary,
            failureMessage: record.failureMessage,
            startedAt: field == .startedAt ? record.startedAt.addingTimeInterval(1) : record.startedAt,
            finishedAt: record.finishedAt
        )
    }

    private func terminalReplacement(
        _ record: RunRecord,
        recoveryID: UUID? = nil,
        syncSummary: ActivitySyncSummary? = nil,
        writeSummary: RunWriteSummary? = nil,
        failureMessage: String? = nil
    ) -> RunRecord {
        RunRecord(
            runID: record.runID,
            requestID: record.requestID,
            trigger: record.trigger,
            intent: record.intent,
            scope: record.scope,
            configuration: record.configuration,
            writeTarget: record.writeTarget,
            recoveryID: recoveryID ?? record.recoveryID,
            transitions: record.transitions,
            syncSummary: syncSummary ?? record.syncSummary,
            writeSummary: writeSummary ?? record.writeSummary,
            failureMessage: failureMessage ?? record.failureMessage,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt
        )
    }
}

private enum ImmutableRunField: String, CaseIterable {
    case requestID, trigger, intent, writeTarget, startedAt
}
