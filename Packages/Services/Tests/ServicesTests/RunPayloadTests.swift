import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run payload persistence")
struct RunPayloadTests {
    @Test("upsert inserts and loadAll round-trips all fields")
    func roundTripsAllFields() async throws {
        let store = try makeRunStore()
        let writeTarget = FixPlanWriteTarget(
            planID: FixPlanID(),
            planRevision: FixPlanRevision(2),
            decisionRevision: ReviewDecisionRevision(3)
        )
        let recoveryID = UUID()
        let record = makeRunRecord(
            intent: .writeFixes,
            writeTarget: writeTarget,
            recoveryID: recoveryID,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completed,
            syncSummary: ActivitySyncSummary(new: 2, modified: 1, identityChanged: 0, refreshed: 1, removed: 3),
            writeSummary: RunWriteSummary(applied: 1, verifiedNoOp: 2, failed: 3)
        )

        try await store.upsert(record)
        let loaded = try await store.loadAll()

        #expect(loaded == [record])
        #expect(loaded.first?.configuration?.mode == .autoFix)
        #expect(loaded.first?.configuration?.writeAuthority == .reviewedPlan)
        #expect(loaded.first?.configuration?.settings.id == record.configuration?.settings.id)
    }

    @Test("Version 1 payload loads without run configuration")
    func loadsVersionOnePayload() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .completedNoOp, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(LegacyPayload(transitions: transitions)),
            state: .completedNoOp,
            finishedAt: Date(timeIntervalSince1970: 101),
            into: container
        )

        let loaded = try await RunRecordDataStore(modelContainer: container).loadAll()

        #expect(loaded.map(\.runID) == [RunID(rawValue: runID)])
        #expect(loaded.first?.transitions == transitions)
        #expect(loaded.first?.configuration == nil)
    }

    @Test("Records without run configuration persist as version 1")
    func writesLegacyPayload() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 101)
        let record = RunRecord(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 10,
                createdAt: startedAt,
                reason: "manualCheck"
            ),
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .completedNoOp, timestamp: finishedAt),
            ],
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 0),
            failureMessage: nil,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        try await store.upsert(record)

        #expect(try await store.loadAll() == [record])
    }

    @Test("Invalid terminal run configuration is reported as corrupted")
    func reportsCorruptConfiguration() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let target = FixPlanWriteTarget(
            planID: FixPlanID(),
            planRevision: FixPlanRevision(2),
            decisionRevision: ReviewDecisionRevision(3)
        )
        let summary = RunWriteSummary(applied: 1, verifiedNoOp: 2, failed: 3)
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .completed, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(CorruptedConfigPayload(
                transitions: transitions,
                writeTarget: target,
                recoveryID: runID,
                writeSummary: summary
            )),
            intent: .writeFixes,
            finishedAt: Date(timeIntervalSince1970: 101),
            into: container
        )

        let store = RunRecordDataStore(modelContainer: container)
        let page = try await store.reports(matching: RunReportQuery())

        do {
            _ = try await store.loadAll()
            Issue.record("Expected invalid configuration to fail decoding")
        } catch let RunRecordPersistenceError.corruptedField(name, errorRunID) {
            #expect(name == "configuration")
            #expect(errorRunID == runID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
        #expect(page.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(page.recoveryRunIDs.isEmpty)
    }

    @Test("Version 2 payload requires run configuration")
    func rejectsMissingConfiguration() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .completedNoOp, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(MissingConfigPayload(transitions: transitions)),
            state: .completedNoOp,
            finishedAt: Date(timeIntervalSince1970: 101),
            into: container
        )

        do {
            _ = try await RunRecordDataStore(modelContainer: container).loadAll()
            Issue.record("Expected missing configuration to fail decoding")
        } catch let RunRecordPersistenceError.corruptedField(name, errorRunID) {
            #expect(name == "configuration")
            #expect(errorRunID == runID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Malformed object versions require explicit corrupted-run closure")
    func closesMalformedVersions() async throws {
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .recoverable, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        let payloads = try [
            JSONEncoder().encode(MissingVersionPayload(transitions: transitions)),
            JSONEncoder().encode(WrongVersionPayload(transitions: transitions)),
        ]

        for payload in payloads {
            let container = try ModelContainerFactory.createInMemory()
            let runID = UUID()
            try insertRunRow(
                runID: runID,
                transitionsData: payload,
                intent: .writeFixes,
                state: .recoverable,
                into: container
            )
            let store = RunRecordDataStore(modelContainer: container)

            do {
                _ = try await store.loadAll()
                Issue.record("Expected malformed payload version to fail decoding")
            } catch let RunRecordPersistenceError.malformedPayloadVersion(errorRunID) {
                #expect(errorRunID == runID)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
            #expect(try await store.record(for: RunID(rawValue: runID))?.state == .cancelled)
        }
    }

    @Test("Version 1 payload rejects run configuration")
    func rejectsLegacyConfig() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = LegacyConfigPayload(
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .completedNoOp, timestamp: startedAt.addingTimeInterval(1)),
            ],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(payload),
            scopeData: JSONEncoder().encode(scope),
            state: .completedNoOp,
            finishedAt: startedAt.addingTimeInterval(1),
            into: container
        )

        await assertCorruptedRunField(
            store: RunRecordDataStore(modelContainer: container),
            expectedName: "configuration",
            expectedRunID: runID
        )
    }
}
