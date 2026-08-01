import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run record retention")
struct RunRetentionTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("unresolved outcomes survive prune beyond the limit")
    func unresolvedOutcomesSurvivePrune() async throws {
        let store = try makeStore()
        let needsReview = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.needsReview))])
        let deferred = writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.deferred))])
        let landedA = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        let landedB = writeRecord(at: 3, items: [makeWorkItem(state: .outcome(.written))])
        let landedC = writeRecord(at: 4, items: [makeWorkItem(state: .outcome(.written))])
        for record in [needsReview, deferred, landedA, landedB, landedC] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 2)
        #expect(try await store.record(for: needsReview.runID) != nil)
        #expect(try await store.record(for: deferred.runID) != nil)
        #expect(try await store.record(for: landedC.runID) != nil)
        #expect(try await store.record(for: landedA.runID) == nil)
        #expect(try await store.record(for: landedB.runID) == nil)
    }

    @Test("continuable work protects only sources with a recorded plan")
    func continuableWorkNeedsRecordedPlan() async throws {
        let store = try makeStore()
        let continuable = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.failed))])
        let planless = writeRecord(
            at: 1,
            target: nil,
            items: [makeWorkItem(state: .outcome(.failed))]
        )
        let newest = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        for record in [continuable, planless, newest] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 1)
        #expect(try await store.record(for: continuable.runID) != nil)
        #expect(try await store.record(for: planless.runID) == nil)
        #expect(try await store.record(for: newest.runID) != nil)
    }

    @Test("a retained continuation keeps its source chain alive")
    func retainedContinuationKeepsSourceChain() async throws {
        let store = try makeStore()
        let sourceA = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        let linkB = writeRecord(
            at: 1,
            continues: sourceA.runID,
            items: [makeWorkItem(state: .outcome(.written))]
        )
        let fillerA = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        let fillerB = writeRecord(at: 3, items: [makeWorkItem(state: .outcome(.written))])
        let headC = writeRecord(
            at: 4,
            continues: linkB.runID,
            items: [makeWorkItem(state: .outcome(.written))]
        )
        for record in [sourceA, linkB, fillerA, fillerB, headC] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        // headC holds the single slot and references linkB, which references
        // sourceA — the whole chain survives while the fillers prune.
        #expect(deleted == 2)
        #expect(try await store.record(for: headC.runID) != nil)
        #expect(try await store.record(for: linkB.runID) != nil)
        #expect(try await store.record(for: sourceA.runID) != nil)
        #expect(try await store.record(for: fillerA.runID) == nil)
        #expect(try await store.record(for: fillerB.runID) == nil)
    }

    @Test("an open continuation protects its terminal source")
    func openContinuationProtectsSource() async throws {
        let store = try makeStore()
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        let filler = writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))])
        let newest = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        let openContinuation = makeRunRecord(
            startedAt: baseDate.addingTimeInterval(30),
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
        for record in [source, filler, newest, openContinuation] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 1)
        #expect(try await store.record(for: source.runID) != nil)
        #expect(try await store.record(for: filler.runID) == nil)
        #expect(try await store.record(for: openContinuation.runID) != nil)
    }

    @Test("a pruned continuation stops protecting its source")
    func prunedContinuationDropsSourceProtection() async throws {
        let store = try makeStore()
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        let link = writeRecord(
            at: 1,
            continues: source.runID,
            items: [makeWorkItem(state: .outcome(.written))]
        )
        let newest = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, link, newest] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        // link is itself prunable and beyond the limit; once it goes, its
        // reference goes with it and the source is plain history too.
        #expect(deleted == 2)
        #expect(try await store.record(for: newest.runID) != nil)
        #expect(try await store.record(for: link.runID) == nil)
        #expect(try await store.record(for: source.runID) == nil)
    }

    @Test("protected records do not consume history slots")
    func protectedRecordsRideOnTop() async throws {
        let store = try makeStore()
        let oldest = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        let middle = writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))])
        let protected = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.needsReview))])
        for record in [oldest, middle, protected] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        // The protected record rides on top: middle takes the single
        // prunable slot and only oldest is deleted.
        #expect(deleted == 1)
        #expect(try await store.record(for: protected.runID) != nil)
        #expect(try await store.record(for: middle.runID) != nil)
        #expect(try await store.record(for: oldest.runID) == nil)
    }

    @Test("a prunable corrupted row prunes; orphaned child rows protect it")
    func corruptedRowPruningRespectsChildEvidence() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: baseDate,
            reason: "manualCheck"
        )
        // Read-only intent with a reviewed-plan configuration cannot decode as
        // a healthy record, but salvage-decodes cleanly — the prunable
        // corrupted shape (readOnlyClosure route, no write evidence).
        func insertCorruptedRow(runID: UUID) throws {
            try insertRunRow(
                runID: runID,
                transitionsData: JSONEncoder().encode(VersionedPayload(
                    transitions: [
                        RunLifecycleTransition(state: .created, timestamp: baseDate),
                        RunLifecycleTransition(state: .cancelled, timestamp: baseDate.addingTimeInterval(5)),
                    ],
                    configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: baseDate)
                )),
                input: RunRowInput(
                    scopeData: JSONEncoder().encode(scope),
                    intent: .observeLibrary,
                    state: .cancelled,
                    startedAt: baseDate,
                    finishedAt: baseDate.addingTimeInterval(5)
                ),
                into: container
            )
        }
        let bareRunID = UUID()
        let parentedRunID = UUID()
        try insertCorruptedRow(runID: bareRunID)
        try insertCorruptedRow(runID: parentedRunID)
        let context = ModelContext(container)
        let orphanItem = makeWorkItem(state: .prepared)
        context.insert(PersistedRunWorkItem(
            runID: parentedRunID,
            itemID: orphanItem.id,
            position: 0,
            itemData: try JSONEncoder().encode(orphanItem)
        ))
        try context.save()
        let store = RunRecordDataStore(modelContainer: container)
        try await store.upsert(writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))]))

        let deleted = try await store.prune(keepingLatest: 1)

        // The bare corrupted row prunes on the read-only route; the one with
        // orphaned child rows fails item reconciliation and is routed to
        // attention — child evidence always protects the parent, so pruning
        // can never strand child rows.
        #expect(deleted == 1)
        let remainingRuns = try ModelContext(container).fetch(
            FetchDescriptor<PersistedRunRecord>()
        )
        #expect(remainingRuns.contains { $0.runID == parentedRunID })
        #expect(!remainingRuns.contains { $0.runID == bareRunID })
        let remainingChildren = try ModelContext(container).fetch(
            FetchDescriptor<PersistedRunWorkItem>()
        )
        #expect(remainingChildren.count == 1)
    }

    private func makeStore() throws -> RunRecordDataStore {
        try RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())
    }

    private func writeRecord(
        at index: Int,
        target: FixPlanWriteTarget? = writeTarget(),
        continues continuesRunID: RunID? = nil,
        items: [RunWorkItem]
    ) -> RunRecord {
        let startedAt = baseDate.addingTimeInterval(Double(index) * 10)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: target,
                continuesRunID: continuesRunID,
                workItems: items,
                includesSyncTransition: false
            )
        )
    }
}
