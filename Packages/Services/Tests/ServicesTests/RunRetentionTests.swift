import Core
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

    @Test("pruned runs take their change-log entries; legacy entries survive")
    func prunedRunDeletesItsChangeLogEntries() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let changeLog = ChangeLogDataStore(modelContainer: container)
        let doomed = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        let kept = writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))])
        try await store.upsert(doomed)
        try await store.upsert(kept)

        var doomedEntry = ChangeLogEntry(changeType: .genreUpdate, trackID: "T1", artist: "Artist")
        doomedEntry.runID = doomed.runID.rawValue
        var keptEntry = ChangeLogEntry(changeType: .genreUpdate, trackID: "T2", artist: "Artist")
        keptEntry.runID = kept.runID.rawValue
        let legacyEntry = ChangeLogEntry(changeType: .genreUpdate, trackID: "T3", artist: "Artist")
        try await changeLog.saveEntries([doomedEntry, keptEntry, legacyEntry])

        let deleted = try await store.prune(keepingLatest: 1)

        let remaining = try await changeLog.loadAll()
        #expect(deleted == 1)
        #expect(Set(remaining.map(\.id)) == [keptEntry.id, legacyEntry.id])
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
        /// Read-only intent with a reviewed-plan configuration cannot decode as
        /// a healthy record, but salvage-decodes cleanly — the prunable
        /// corrupted shape (readOnlyClosure route, no write evidence).
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
        try context.insert(PersistedRunWorkItem(
            runID: parentedRunID,
            itemID: orphanItem.id,
            position: 0,
            itemData: JSONEncoder().encode(orphanItem)
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

    @Test("a protected corrupted referencer keeps its source alive")
    func corruptedReferencerProtectsSource() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        try await store.upsert(source)
        try await store.upsert(writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))]))
        let corruptedRunID = UUID()
        let corruptedStart = baseDate.addingTimeInterval(20)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: corruptedStart,
            reason: "manualCheck"
        )
        // Finished header over a payload that ends mid-write: interrupted
        // write evidence — a protected corrupted row that references source.
        try insertRunRow(
            runID: corruptedRunID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: corruptedStart),
                    RunLifecycleTransition(state: .writing, timestamp: corruptedStart.addingTimeInterval(1)),
                ],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: corruptedStart),
                continuesRunID: source.runID
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .writing,
                startedAt: corruptedStart,
                finishedAt: corruptedStart.addingTimeInterval(2)
            ),
            into: container
        )

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 0)
        #expect(try await store.record(for: source.runID) != nil)
    }

    @Test("an unreadable forward-schema referencer still protects its source")
    func forwardSchemaReferencerProtectsSource() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        try await store.upsert(source)
        try await store.upsert(writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))]))
        let forwardStart = baseDate.addingTimeInterval(20)
        try insertRunRow(
            runID: UUID(),
            transitionsData: JSONEncoder().encode(ForwardRunPayload(
                transitions: [RunLifecycleTransition(state: .cancelled, timestamp: forwardStart)],
                continuesRunID: source.runID
            )),
            input: RunRowInput(
                state: .cancelled,
                startedAt: forwardStart,
                finishedAt: forwardStart.addingTimeInterval(1)
            ),
            into: container
        )

        let deleted = try await store.prune(keepingLatest: 1)

        // The forward-version row is retained fail-closed; its reference is
        // salvaged per-field and must keep protecting the source.
        #expect(deleted == 0)
        #expect(try await store.record(for: source.runID) != nil)
    }

    @Test("pruning a healthy record deletes its child work-item rows")
    func prunedHealthyRecordDeletesChildRows() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let landedItem = makeWorkItem(state: .outcome(.written))
        let prunable = writeRecord(at: 0, items: [landedItem])
        try await store.upsert(prunable)
        try await store.upsert(writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))]))
        let context = ModelContext(container)
        try context.insert(PersistedRunWorkItem(
            runID: prunable.runID.rawValue,
            itemID: landedItem.id,
            position: 0,
            itemData: JSONEncoder().encode(landedItem)
        ))
        try context.save()

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 1)
        #expect(try await store.record(for: prunable.runID) == nil)
        let remainingChildren = try ModelContext(container).fetch(
            FetchDescriptor<PersistedRunWorkItem>()
        )
        #expect(remainingChildren.isEmpty)
    }

    @Test("a landed continuation consumes its source's continuation evidence")
    func landedContinuationConsumesSourceEvidence() async throws {
        let store = try makeStore()
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.failed))])
        let landedContinuation = writeRecord(
            at: 1,
            continues: source.runID,
            items: [makeWorkItem(state: .outcome(.written))]
        )
        let newestA = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        let newestB = writeRecord(at: 3, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, landedContinuation, newestA, newestB] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        // The continuation landed everything, so the source's failed items
        // are re-applied history, not current evidence — once the pruned
        // continuation stops referencing it, the whole chain dissolves.
        #expect(deleted == 3)
        #expect(try await store.record(for: newestB.runID) != nil)
        #expect(try await store.record(for: source.runID) == nil)
        #expect(try await store.record(for: landedContinuation.runID) == nil)
    }

    @Test("a failed continuation does not consume its source's evidence")
    func failedContinuationKeepsSourceEvidence() async throws {
        let store = try makeStore()
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.failed))])
        let failedContinuation = writeRecord(
            at: 1,
            continues: source.runID,
            items: [makeWorkItem(state: .outcome(.failed))]
        )
        let newest = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, failedContinuation, newest] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 0)
        #expect(try await store.record(for: source.runID) != nil)
        #expect(try await store.record(for: failedContinuation.runID) != nil)
    }

    @Test("a failed link in a chain blocks consumption of the root source")
    func failedChainLinkBlocksRootConsumption() async throws {
        let store = try makeStore()
        // S <- failed C1 <- landed C2: C2 consumes C1 (its failed work was
        // re-applied), so C1 prunes with the fillers — but C1, having failed,
        // consumed NOTHING of S. S must survive on its own evidence. A mutant
        // that lets failed continuations register consumption deletes S.
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.failed))])
        let failedLink = writeRecord(
            at: 1,
            continues: source.runID,
            items: [makeWorkItem(state: .outcome(.failed))]
        )
        let landedHead = writeRecord(
            at: 2,
            continues: failedLink.runID,
            items: [makeWorkItem(state: .outcome(.written))]
        )
        let newestA = writeRecord(at: 3, items: [makeWorkItem(state: .outcome(.written))])
        let newestB = writeRecord(at: 4, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, failedLink, landedHead, newestA, newestB] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(try await store.record(for: source.runID) != nil)
        #expect(try await store.record(for: newestB.runID) != nil)
        #expect(try await store.record(for: failedLink.runID) == nil)
        #expect(deleted == 3)
    }

    @Test("an open continuation does not consume its source's evidence")
    func openContinuationDoesNotConsumeEvidence() async throws {
        let store = try makeStore()
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.failed))])
        let openContinuation = makeRunRecord(
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
        let newest = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, openContinuation, newest] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        // In-flight work consumes nothing; the source keeps both its own
        // evidence protection and the open run's reference.
        #expect(deleted == 0)
        #expect(try await store.record(for: source.runID) != nil)
    }

    @Test("consumption never covers review or deferral outcomes")
    func consumptionSparesUnresolvedOutcomes() async throws {
        let store = try makeStore()
        let source = writeRecord(at: 0, items: [
            makeWorkItem(state: .outcome(.failed)),
            makeWorkItem(state: .outcome(.needsReview)),
        ])
        let landedContinuation = writeRecord(
            at: 1,
            continues: source.runID,
            items: [makeWorkItem(state: .outcome(.written))]
        )
        let newestA = writeRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        let newestB = writeRecord(at: 3, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, landedContinuation, newestA, newestB] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        // needsReview is a user decision; no continuation can consume it.
        #expect(deleted == 2)
        #expect(try await store.record(for: source.runID) != nil)
        #expect(try await store.record(for: landedContinuation.runID) == nil)
    }

    @Test("a fully unreadable referencer cannot protect its source")
    func unreadableReferencerCannotProtectSource() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let source = writeRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        try await store.upsert(source)
        try await store.upsert(writeRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))]))
        try insertRunRow(
            runID: UUID(),
            transitionsData: Data("not-json".utf8),
            input: RunRowInput(
                state: .cancelled,
                startedAt: baseDate.addingTimeInterval(20),
                finishedAt: baseDate.addingTimeInterval(21)
            ),
            into: container
        )

        let deleted = try await store.prune(keepingLatest: 1)

        // The garbage row itself is retained fail-closed, but its reference
        // (if it ever had one) is unrecoverable — the source is plain history.
        // Documented best-effort trade; the loss is logged.
        #expect(deleted == 1)
        #expect(try await store.record(for: source.runID) == nil)
    }

    @Test("an ordering violation aborts the pass instead of deleting a source")
    func orderingViolationFailsClosed() async throws {
        let store = try makeStore()
        // The continuation deliberately starts BEFORE its source — the shape
        // only a backward clock step can produce. Prune must delete nothing.
        let source = writeRecord(at: 5, items: [makeWorkItem(state: .outcome(.written))])
        let continuation = makeRunRecord(
            startedAt: baseDate,
            finishedAt: baseDate.addingTimeInterval(1),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                continuesRunID: source.runID,
                workItems: [makeWorkItem(state: .outcome(.needsReview))],
                includesSyncTransition: false
            )
        )
        let newestA = writeRecord(at: 6, items: [makeWorkItem(state: .outcome(.written))])
        let newestB = writeRecord(at: 7, items: [makeWorkItem(state: .outcome(.written))])
        for record in [source, continuation, newestA, newestB] {
            try await store.upsert(record)
        }
        // Entries staged for deletion alongside a run must roll back with the
        // aborted pass, or a later unrelated save silently commits them.
        var sourceEntry = ChangeLogEntry(changeType: .genreUpdate, trackID: "T1", artist: "Artist")
        sourceEntry.runID = source.runID.rawValue
        let changeLog = ChangeLogDataStore(modelContainer: store.modelContainer)
        try await changeLog.saveEntry(sourceEntry)

        let deleted = try await store.prune(keepingLatest: 1)

        #expect(deleted == 0)
        #expect(try await store.record(for: source.runID) != nil)
        #expect(try await store.record(for: continuation.runID) != nil)
        #expect(try await changeLog.loadAll().map(\.id) == [sourceEntry.id])
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

private struct ForwardRunPayload: Encodable {
    let version = RunRecordPayload.currentVersion + 1
    let transitions: [RunLifecycleTransition]
    let continuesRunID: RunID?
}
