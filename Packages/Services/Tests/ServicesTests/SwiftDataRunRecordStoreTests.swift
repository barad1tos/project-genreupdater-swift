import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("SwiftDataRunRecordStore")
struct SwiftDataRunRecordStoreTests {
    @Test("upsert inserts and loadAll round-trips all fields")
    func upsertInsertsAndLoadAllRoundTripsAllFields() async throws {
        let store = try makeStore()
        let record = makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completed,
            syncSummary: ActivitySyncSummary(new: 2, modified: 1, identityChanged: 0, refreshed: 1, removed: 3)
        )

        try await store.upsert(record)
        let loaded = try await store.loadAll()

        #expect(loaded == [record])
    }

    @Test("upsert with the same run updates the open record to final")
    func upsertSameRunUpdatesOpenRecordToFinal() async throws {
        let store = try makeStore()
        let open = makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let final = makeRecord(
            runID: open.runID,
            requestID: open.requestID,
            startedAt: open.startedAt,
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completedNoOp,
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 0)
        )

        try await store.upsert(open)
        try await store.upsert(final)
        let loaded = try await store.loadAll()

        #expect(loaded == [final])
    }

    @Test("record(for:) returns the match or nil")
    func recordForIDReturnsMatchOrNil() async throws {
        let store = try makeStore()
        let record = makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        try await store.upsert(record)

        #expect(try await store.record(for: record.runID) == record)
        #expect(try await store.record(for: RunID()) == nil)
    }

    @Test("loadAll sorts by startedAt descending")
    func loadAllSortsByStartedAtDescending() async throws {
        let store = try makeStore()
        let older = makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        )
        let newer = makeRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completedNoOp,
            syncSummary: nil
        )

        try await store.upsert(older)
        try await store.upsert(newer)

        #expect(try await store.loadAll().map(\.runID) == [newer.runID, older.runID])
    }

    @Test("loadAll throws corruptedField naming transitions for garbage transition bytes")
    func loadAllThrowsCorruptedFieldForGarbageTransitionBytes() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertPersistedRunRecord(runID: runID, transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]), into: container)

        let store = SwiftDataRunRecordStore(modelContainer: container)

        await assertLoadAllThrowsCorruptedField(store: store, expectedName: "transitions", expectedRunID: runID)
    }

    @Test("loadAll throws corruptedField naming transitions for an empty transitions array")
    func loadAllThrowsCorruptedFieldForEmptyTransitionsArray() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let emptyTransitionsData = try JSONEncoder().encode([RunLifecycleTransition]())
        try insertPersistedRunRecord(runID: runID, transitionsData: emptyTransitionsData, into: container)

        let store = SwiftDataRunRecordStore(modelContainer: container)

        await assertLoadAllThrowsCorruptedField(store: store, expectedName: "transitions", expectedRunID: runID)
    }

    @Test("loadAll throws corruptedField naming scope for garbage scope bytes")
    func loadAllThrowsCorruptedFieldForGarbageScopeBytes() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertPersistedRunRecord(
            runID: runID,
            transitionsData: validTransitionsData(),
            scopeData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            into: container
        )

        let store = SwiftDataRunRecordStore(modelContainer: container)

        await assertLoadAllThrowsCorruptedField(store: store, expectedName: "scope", expectedRunID: runID)
    }

    @Test("prune keeps the newest terminal records and reports the deleted count")
    func pruneKeepsNewestTerminalRecords() async throws {
        let store = try makeStore()
        for offset in 0 ..< 3 {
            try await store.upsert(makeRecord(
                startedAt: Date(timeIntervalSince1970: 100 + Double(offset) * 100),
                finishedAt: Date(timeIntervalSince1970: 150 + Double(offset) * 100),
                state: .completedNoOp,
                syncSummary: nil
            ))
        }

        let deleted = try await store.prune(keepingLatest: 2)

        let remaining = try await store.loadAll()
        #expect(deleted == 1)
        #expect(remaining.count == 2)
        #expect(remaining.map(\.startedAt) == [
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 200),
        ])
    }

    @Test("prune never deletes open records")
    func pruneNeverDeletesOpenRecords() async throws {
        let store = try makeStore()
        let open = makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        try await store.upsert(open)
        for offset in 0 ..< 2 {
            try await store.upsert(makeRecord(
                startedAt: Date(timeIntervalSince1970: 200 + Double(offset) * 100),
                finishedAt: Date(timeIntervalSince1970: 250 + Double(offset) * 100),
                state: .completed,
                syncSummary: nil
            ))
        }

        let deleted = try await store.prune(keepingLatest: 1)

        let remaining = try await store.loadAll()
        #expect(deleted == 1)
        #expect(remaining.contains { $0.runID == open.runID })
        #expect(remaining.count == 2)
    }

    @Test("prune under the limit deletes nothing")
    func pruneUnderLimitDeletesNothing() async throws {
        let store = try makeStore()
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))

        #expect(try await store.prune(keepingLatest: 5) == 0)
        #expect(try await store.loadAll().count == 1)
    }

    @Test("prune at exactly the limit deletes nothing")
    func pruneAtExactlyTheLimitDeletesNothing() async throws {
        let store = try makeStore()
        for offset in 0 ..< 2 {
            try await store.upsert(makeRecord(
                startedAt: Date(timeIntervalSince1970: 100 + Double(offset) * 100),
                finishedAt: Date(timeIntervalSince1970: 150 + Double(offset) * 100),
                state: .completedNoOp,
                syncSummary: nil
            ))
        }

        #expect(try await store.prune(keepingLatest: 2) == 0)
        #expect(try await store.loadAll().count == 2)
    }

    @Test("prune with a limit below one is a no-op")
    func pruneWithLimitBelowOneIsNoOp() async throws {
        let store = try makeStore()
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))

        #expect(try await store.prune(keepingLatest: 0) == 0)
        #expect(try await store.prune(keepingLatest: -3) == 0)
        #expect(try await store.loadAll().count == 1)
    }

    @Test("reports date bounds are inclusive at the exact boundary")
    func reportsDateBoundsAreInclusiveAtExactBoundary() async throws {
        let store = try makeStore()
        let boundary = Date(timeIntervalSince1970: 200)
        try await store.upsert(makeRecord(
            startedAt: boundary,
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completedNoOp,
            syncSummary: nil
        ))

        let page = try await store.reports(matching: RunReportQuery(
            startedAfter: boundary,
            startedBefore: boundary
        ))

        #expect(page.records.map(\.startedAt) == [boundary])
    }

    @Test("corrupted rows consume fetch-limit slots")
    func corruptedRowsConsumeFetchLimitSlots() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = SwiftDataRunRecordStore(modelContainer: container)
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try insertPersistedRunRecord(
            runID: UUID(),
            transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            startedAt: Date(timeIntervalSince1970: 200),
            into: container
        )

        let page = try await store.reports(matching: RunReportQuery(limit: 1))

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
    }

    @Test("reports filters by date range and state, newest first")
    func reportsFiltersByDateRangeAndState() async throws {
        let store = try makeStore()
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .failed,
            syncSummary: nil
        ))
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 301),
            state: .completed,
            syncSummary: ActivitySyncSummary(new: 1, modified: 0, identityChanged: 0, refreshed: 0, removed: 0)
        ))

        let all = try await store.reports(matching: RunReportQuery())
        #expect(all.records.map(\.startedAt) == [
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 100),
        ])
        #expect(all.skippedCorruptedCount == 0)

        let dateWindow = try await store.reports(matching: RunReportQuery(
            startedAfter: Date(timeIntervalSince1970: 150),
            startedBefore: Date(timeIntervalSince1970: 250)
        ))
        #expect(dateWindow.records.map(\.startedAt) == [Date(timeIntervalSince1970: 200)])

        let failedOnly = try await store.reports(matching: RunReportQuery(states: [.failed]))
        #expect(failedOnly.records.map(\.state) == [.failed])

        let limited = try await store.reports(matching: RunReportQuery(limit: 2))
        #expect(limited.records.count == 2)
        #expect(limited.records.first?.startedAt == Date(timeIntervalSince1970: 300))

        let zeroLimit = try await store.reports(matching: RunReportQuery(limit: 0))
        #expect(zeroLimit.records.count == 3)

        let emptyStates = try await store.reports(matching: RunReportQuery(states: []))
        #expect(emptyStates.records.count == 3)
    }

    @Test("reports state filter sees the updated terminal state")
    func reportsStateFilterSeesUpdatedTerminalState() async throws {
        let store = try makeStore()
        let open = makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        try await store.upsert(open)
        try await store.upsert(makeRecord(
            runID: open.runID,
            requestID: open.requestID,
            startedAt: open.startedAt,
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completedNoOp,
            syncSummary: nil
        ))

        let noOp = try await store.reports(matching: RunReportQuery(states: [.completedNoOp]))
        let stillOpen = try await store.reports(matching: RunReportQuery(states: [.syncingLibrary]))

        #expect(noOp.records.map(\.runID) == [open.runID])
        #expect(stillOpen.records.isEmpty)
    }

    @Test("reports filters by trigger")
    func reportsFiltersByTrigger() async throws {
        let store = try makeStore()
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try await store.upsert(makeRecord(
            trigger: .recovery,
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completedNoOp,
            syncSummary: nil
        ))

        let recoveryOnly = try await store.reports(matching: RunReportQuery(trigger: .recovery))

        #expect(recoveryOnly.records.map(\.trigger) == [.recovery])
    }

    @Test("reports skips corrupted rows and counts them")
    func reportsSkipsCorruptedRowsAndCountsThem() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = SwiftDataRunRecordStore(modelContainer: container)
        try await store.upsert(makeRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try insertPersistedRunRecord(
            runID: UUID(),
            transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            into: container
        )

        let page = try await store.reports(matching: RunReportQuery())

        #expect(page.records.count == 1)
        #expect(page.skippedCorruptedCount == 1)
    }

    private func validTransitionsData() throws -> Data {
        try JSONEncoder().encode([
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .syncingLibrary, timestamp: Date(timeIntervalSince1970: 101)),
        ])
    }

    private func assertLoadAllThrowsCorruptedField(
        store: SwiftDataRunRecordStore,
        expectedName: String,
        expectedRunID: UUID
    ) async {
        do {
            _ = try await store.loadAll()
            Issue.record("Expected loadAll to throw RunRecordPersistenceError.corruptedField")
        } catch let error as RunRecordPersistenceError {
            guard case let .corruptedField(name, runID) = error else {
                Issue.record("Expected corruptedField, got \(error)")
                return
            }
            #expect(name == expectedName)
            #expect(runID == expectedRunID)
        } catch {
            Issue.record("Expected RunRecordPersistenceError, got \(error)")
        }
    }

    private func insertPersistedRunRecord(
        runID: UUID,
        transitionsData: Data,
        scopeData: Data? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 100),
        into container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let scopeData = try scopeData ?? JSONEncoder().encode(ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "manualCheck"
        ))
        context.insert(PersistedRunRecord(
            runID: runID,
            requestID: UUID(),
            triggerRaw: RunTrigger.manualCheck.rawValue,
            intentRaw: RunIntent.observeLibrary.rawValue,
            stateRaw: RunLifecycleState.completed.rawValue,
            scopeData: scopeData,
            transitionsData: transitionsData,
            syncNewCount: nil,
            syncModifiedCount: nil,
            syncIdentityChangedCount: nil,
            syncRefreshedCount: nil,
            syncRemovedCount: nil,
            failureMessage: nil,
            startedAt: startedAt,
            finishedAt: nil
        ))
        try context.save()
    }

    private func makeStore() throws -> SwiftDataRunRecordStore {
        let container = try ModelContainerFactory.createInMemory()
        return SwiftDataRunRecordStore(modelContainer: container)
    }

    private func makeRecord(
        runID: RunID = RunID(),
        requestID: RunRequestID = RunRequestID(),
        trigger: RunTrigger = .manualCheck,
        startedAt: Date,
        finishedAt: Date?,
        state: RunLifecycleState,
        syncSummary: ActivitySyncSummary?
    ) -> RunRecord {
        var transitions = [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .syncingLibrary, timestamp: startedAt.addingTimeInterval(1)),
        ]
        if state != .syncingLibrary {
            transitions.append(RunLifecycleTransition(
                state: state,
                timestamp: finishedAt ?? startedAt.addingTimeInterval(2)
            ))
        }

        return RunRecord(
            runID: runID,
            requestID: requestID,
            trigger: trigger,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Aphex Twin"],
                knownTrackCount: 75,
                createdAt: startedAt,
                reason: "manualCheck"
            ),
            transitions: transitions,
            syncSummary: syncSummary,
            failureMessage: state == .failed ? "Music.app unavailable" : nil,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}
