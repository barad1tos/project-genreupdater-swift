import Foundation
import Testing
@testable import Services

@Suite("RunRecordSink")
struct RunRecordSinkTests {
    @Test("terminal persist prunes history to the current limit")
    func terminalPersistPrunesHistoryToLimit() async throws {
        let store = try makeStore()
        let sink = RunRecordSink.make(store: store, historyLimit: { 1 })

        try await sink(makeRecord(startedAt: 100, finishedAt: 150))
        try await sink(makeRecord(startedAt: 200, finishedAt: 250))

        let remaining = try await store.loadAll()
        #expect(remaining.map(\.startedAt) == [Date(timeIntervalSince1970: 200)])
    }

    @Test("open persist does not prune")
    func openPersistDoesNotPrune() async throws {
        let store = try makeStore()
        try await store.upsert(makeRecord(startedAt: 100, finishedAt: 150))
        try await store.upsert(makeRecord(startedAt: 200, finishedAt: 250))
        let sink = RunRecordSink.make(store: store, historyLimit: { 1 })

        try await sink(makeRecord(startedAt: 300, finishedAt: nil))

        #expect(try await store.loadAll().count == 3)
    }

    @Test("prune reads the live history limit")
    func pruneReadsLiveHistoryLimit() async throws {
        let store = try makeStore()
        let limitBox = LimitBox(value: 10)
        let sink = RunRecordSink.make(
            store: store,
            historyLimit: { await limitBox.current() }
        )

        try await sink(makeRecord(startedAt: 100, finishedAt: 150))
        try await sink(makeRecord(startedAt: 200, finishedAt: 250))
        #expect(try await store.loadAll().count == 2)

        await limitBox.set(1)
        try await sink(makeRecord(startedAt: 300, finishedAt: 350))

        #expect(try await store.loadAll().map(\.startedAt) == [Date(timeIntervalSince1970: 300)])
    }

    @Test("nil history limit skips pruning")
    func nilHistoryLimitSkipsPruning() async throws {
        let store = PruneCountingStore()
        let sink = RunRecordSink.make(store: store, historyLimit: { nil })

        try await sink(makeRecord(startedAt: 300, finishedAt: 350))

        #expect(await store.upsertedCount() == 1)
        #expect(await store.pruneCallCount() == 0)
    }

    @Test("prune failure does not fail the persist")
    func pruneFailureDoesNotFailPersist() async throws {
        let store = PruneThrowingStore()
        let sink = RunRecordSink.make(store: store, historyLimit: { 1 })

        try await sink(makeRecord(startedAt: 100, finishedAt: 150))

        #expect(await store.upsertedCount() == 1)
    }

    private func makeStore() throws -> RunRecordDataStore {
        let container = try ModelContainerFactory.createInMemory()
        return RunRecordDataStore(modelContainer: container)
    }

    private func makeRecord(startedAt: TimeInterval, finishedAt: TimeInterval?) -> RunRecord {
        let started = Date(timeIntervalSince1970: startedAt)
        var transitions = [
            RunLifecycleTransition(state: .created, timestamp: started),
            RunLifecycleTransition(state: .syncingLibrary, timestamp: started.addingTimeInterval(1)),
        ]
        if let finishedAt {
            transitions.append(RunLifecycleTransition(
                state: .completedNoOp,
                timestamp: Date(timeIntervalSince1970: finishedAt)
            ))
        }

        return RunRecord(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: started,
                reason: "manualCheck"
            ),
            transitions: transitions,
            syncSummary: nil,
            failureMessage: nil,
            startedAt: started,
            finishedAt: finishedAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private actor LimitBox {
    private var value: Int

    init(value: Int) {
        self.value = value
    }

    func current() -> Int {
        value
    }

    func set(_ newValue: Int) {
        value = newValue
    }
}

private actor PruneCountingStore: RunRecordStore {
    private var upserted: [RunRecord] = []
    private var pruneCalls = 0

    func upsert(_ record: RunRecord) async throws {
        upserted.append(record)
    }

    func loadAll() async throws -> [RunRecord] {
        upserted
    }

    func record(for runID: RunID) async throws -> RunRecord? {
        upserted.first { $0.runID == runID }
    }

    func prune(keepingLatest _: Int) async throws -> Int {
        pruneCalls += 1
        return 0
    }

    func reports(matching _: RunReportQuery) async throws -> RunReportPage {
        RunReportPage(records: upserted, skippedCorruptedCount: 0)
    }

    func upsertedCount() -> Int {
        upserted.count
    }

    func pruneCallCount() -> Int {
        pruneCalls
    }
}

private actor PruneThrowingStore: RunRecordStore {
    private var upserted: [RunRecord] = []

    func upsert(_ record: RunRecord) async throws {
        upserted.append(record)
    }

    func loadAll() async throws -> [RunRecord] {
        upserted
    }

    func record(for runID: RunID) async throws -> RunRecord? {
        upserted.first { $0.runID == runID }
    }

    func prune(keepingLatest _: Int) async throws -> Int {
        throw PruneProbeError()
    }

    func reports(matching _: RunReportQuery) async throws -> RunReportPage {
        RunReportPage(records: upserted, skippedCorruptedCount: 0)
    }

    func upsertedCount() -> Int {
        upserted.count
    }
}

private struct PruneProbeError: Error {}
