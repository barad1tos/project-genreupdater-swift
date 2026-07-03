import Foundation
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

    private func makeStore() throws -> SwiftDataRunRecordStore {
        let container = try ModelContainerFactory.createInMemory()
        return SwiftDataRunRecordStore(modelContainer: container)
    }

    private func makeRecord(
        runID: RunID = RunID(),
        requestID: RunRequestID = RunRequestID(),
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
            trigger: .manualCheck,
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
