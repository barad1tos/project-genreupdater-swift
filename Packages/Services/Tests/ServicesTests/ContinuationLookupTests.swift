import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Continuation lookup")
struct ContinuationLookupTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("continuations of a source list newest first")
    func continuationsListNewestFirst() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0)
        let older = writeRecord(at: 1, continues: source.runID)
        let newer = writeRecord(at: 2, continues: source.runID)
        let unrelated = writeRecord(at: 3)
        for record in [source, older, newer, unrelated] {
            try await store.upsert(record)
        }

        let continuations = try await store.continuations(of: source.runID)

        #expect(continuations == [newer.runID, older.runID])
    }

    @Test("a legacy row without the column is still listed")
    func legacyRowStillListed() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0)
        let continuation = writeRecord(at: 1, continues: source.runID)
        try await store.upsert(source)
        try await store.upsert(continuation)

        let context = ModelContext(container)
        let continuationRunID = continuation.runID.rawValue
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.runID == continuationRunID }
        )).first)
        row.continuesRunID = nil
        try context.save()

        let continuations = try await store.continuations(of: source.runID)

        #expect(continuations == [continuation.runID])
    }

    @Test("a corrupted continuation row is never listed")
    func corruptedContinuationNotListed() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0)
        let continuation = writeRecord(at: 1, continues: source.runID)
        try await store.upsert(source)
        try await store.upsert(continuation)

        let context = ModelContext(container)
        let continuationRunID = continuation.runID.rawValue
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.runID == continuationRunID }
        )).first)
        row.scopeData = Data("garbage".utf8)
        try context.save()

        let continuations = try await store.continuations(of: source.runID)

        #expect(continuations.isEmpty)
    }

    @Test("an open continuation is listed")
    func openContinuationListed() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0)
        let open = makeRunRecord(
            startedAt: baseDate.addingTimeInterval(10),
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                continuesRunID: source.runID,
                workItems: [makeWorkItem(state: .prepared)],
                includesSyncTransition: false
            )
        )
        try await store.upsert(source)
        try await store.upsert(open)

        let continuations = try await store.continuations(of: source.runID)

        #expect(continuations == [open.runID])
    }

    @Test("a run without continuations lists none")
    func unknownRunListsNone() async throws {
        let store = try RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())

        let continuations = try await store.continuations(of: RunID())

        #expect(continuations.isEmpty)
    }

    private func writeRecord(at index: Int, continues continuesRunID: RunID? = nil) -> RunRecord {
        let startedAt = baseDate.addingTimeInterval(Double(index) * 10)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                continuesRunID: continuesRunID,
                workItems: [makeWorkItem(state: .outcome(.written))],
                includesSyncTransition: false
            )
        )
    }
}
