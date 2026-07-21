import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("RunRecordDataStore")
struct RunRecordDataTests {
    @Test("record(for:) returns the match or nil")
    func loadsRecordByID() async throws {
        let store = try makeRunStore()
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        try await store.upsert(record)

        #expect(try await store.record(for: record.runID) == record)
        #expect(try await store.record(for: RunID()) == nil)
    }

    @Test("work checkpoints survive store recreation without rewriting the run payload")
    func checkpointsSurviveReopen() async throws {
        let container = try ModelContainerFactory.createInMemory()
        var store = RunRecordDataStore(modelContainer: container)
        let detail = "Reviewed metadata correction"
        let item = makeWorkItem(state: .prepared, detail: detail)
        let startedAt = Date(timeIntervalSince1970: 100)
        let input = RunRecordInput(
            intent: .writeFixes,
            workItems: [item],
            includesSyncTransition: false
        )
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: input
        )
        try await store.upsert(record)
        let originalPayload = try runPayload(runID: record.runID, in: container)

        let boundaries: [(WorkCheckpoint, WorkState)] = [
            (.beforeAttempt([item.id]), .attempting),
            (.afterAttempt([item.id]), .attempted),
            (.afterVerification([item.id: .written]), .outcome(.written)),
        ]
        for (checkpoint, expectedState) in boundaries {
            try await store.checkpoint(checkpoint, runID: record.runID)
            store = RunRecordDataStore(modelContainer: container)
            let storedItem = try #require(try await store.record(for: record.runID)?.workItems.first)
            #expect(storedItem.state == expectedState)
            #expect(storedItem.detail == detail)
        }

        #expect(try runPayload(runID: record.runID, in: container) == originalPayload)
    }

    @Test("Work checkpoints decode only addressed items")
    func checkpointsAddressedItems() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let items = [makeWorkItem(state: .prepared), makeWorkItem(state: .prepared)]
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: items,
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<PersistedRunWorkItem>())
        let unrelated = try #require(rows.first { $0.itemID == items[1].id })
        unrelated.itemData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try context.save()

        try await store.checkpoint(.beforeAttempt([items[0].id]), runID: record.runID)

        let currentRows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunWorkItem>())
        let addressed = try #require(currentRows.first { $0.itemID == items[0].id })
        let updated = try JSONDecoder().decode(RunWorkItem.self, from: addressed.itemData)
        #expect(updated.state == .attempting)
    }

    @Test("Adding work-item storage preserves existing run records")
    func migratesWorkItemModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove migration fixture: \(error)")
            }
        }
        let storeURL = directory.appendingPathComponent("GenreUpdater.store")
        let runID = UUID()

        do {
            let legacySchema = runSchema(includesItems: false)
            let legacyConfig = ModelConfiguration(
                "GenreUpdaterMigration",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: [legacyConfig])
            try insertRunRow(runID: runID, transitionsData: validRunTransitionsData(), into: legacyContainer)
        }

        let currentSchema = runSchema(includesItems: true)
        let currentConfig = ModelConfiguration(
            "GenreUpdaterMigration",
            schema: currentSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let currentContainer = try ModelContainer(for: currentSchema, configurations: [currentConfig])
        let context = ModelContext(currentContainer)
        #expect(try context.fetch(FetchDescriptor<PersistedRunRecord>()).map(\.runID) == [runID])

        let item = makeWorkItem(state: .prepared)
        try context.insert(PersistedRunWorkItem(
            runID: runID,
            itemID: item.id,
            position: 0,
            itemData: JSONEncoder().encode(item)
        ))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<PersistedRunWorkItem>()).count == 1)
    }

    @Test("loadAll sorts by startedAt descending")
    func sortsNewestFirst() async throws {
        let store = try makeRunStore()
        let older = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        )
        let newer = makeRunRecord(
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
    func rejectsGarbageTransitions() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(runID: runID, transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]), into: container)

        let store = RunRecordDataStore(modelContainer: container)

        await assertCorruptedRunField(store: store, expectedName: "transitions", expectedRunID: runID)
    }

    @Test("loadAll throws corruptedField naming transitions for an empty transitions array")
    func rejectsEmptyTransitions() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let emptyTransitionsData = try JSONEncoder().encode([RunLifecycleTransition]())
        try insertRunRow(runID: runID, transitionsData: emptyTransitionsData, into: container)

        let store = RunRecordDataStore(modelContainer: container)

        await assertCorruptedRunField(store: store, expectedName: "transitions", expectedRunID: runID)
    }

    @Test("loadAll throws corruptedField naming scope for garbage scope bytes")
    func rejectsGarbageScope() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: validRunTransitionsData(),
            input: RunRowInput(scopeData: Data([0xDE, 0xAD, 0xBE, 0xEF])),
            into: container
        )

        let store = RunRecordDataStore(modelContainer: container)

        await assertCorruptedRunField(store: store, expectedName: "scope", expectedRunID: runID)
    }

    @Test("prune keeps the newest terminal records and reports the deleted count")
    func keepsNewestRuns() async throws {
        let store = try makeRunStore()
        for offset in 0 ..< 3 {
            try await store.upsert(makeRunRecord(
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
    func keepsOpenRuns() async throws {
        let store = try makeRunStore()
        let open = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        try await store.upsert(open)
        for offset in 0 ..< 2 {
            try await store.upsert(makeRunRecord(
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
    func keepsRunsUnderLimit() async throws {
        let store = try makeRunStore()
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))

        #expect(try await store.prune(keepingLatest: 5) == 0)
        #expect(try await store.loadAll().count == 1)
    }

    @Test("prune at exactly the limit deletes nothing")
    func keepsRunsAtLimit() async throws {
        let store = try makeRunStore()
        for offset in 0 ..< 2 {
            try await store.upsert(makeRunRecord(
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
    func ignoresInvalidPruneLimit() async throws {
        let store = try makeRunStore()
        try await store.upsert(makeRunRecord(
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
    func includesDateBoundary() async throws {
        let store = try makeRunStore()
        let boundary = Date(timeIntervalSince1970: 200)
        try await store.upsert(makeRunRecord(
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
    func countsCorruptPageSlots() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try insertRunRow(
            runID: UUID(),
            transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            input: RunRowInput(startedAt: Date(timeIntervalSince1970: 200)),
            into: container
        )

        let page = try await store.reports(matching: RunReportQuery(limit: 1))

        #expect(page.records.isEmpty)
        #expect(page.skippedCorruptedCount == 1)
    }

    @Test("reports filters by date range and state, newest first")
    func filtersHistory() async throws {
        let store = try makeRunStore()
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .failed,
            syncSummary: nil
        ))
        try await store.upsert(makeRunRecord(
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
    func filtersUpdatedState() async throws {
        let store = try makeRunStore()
        let open = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        try await store.upsert(open)
        try await store.upsert(makeRunRecord(
            startedAt: open.startedAt,
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completedNoOp,
            syncSummary: nil,
            input: RunRecordInput(
                runID: open.runID,
                requestID: open.requestID,
                scope: open.scope,
                configuration: open.configuration
            )
        ))

        let noOp = try await store.reports(matching: RunReportQuery(states: [.completedNoOp]))
        let stillOpen = try await store.reports(matching: RunReportQuery(states: [.syncingLibrary]))

        #expect(noOp.records.map(\.runID) == [open.runID])
        #expect(stillOpen.records.isEmpty)
    }

    @Test("reports filters by trigger")
    func filtersByTrigger() async throws {
        let store = try makeRunStore()
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completedNoOp,
            syncSummary: nil,
            input: RunRecordInput(trigger: .recovery)
        ))

        let recoveryOnly = try await store.reports(matching: RunReportQuery(trigger: .recovery))

        #expect(recoveryOnly.records.map(\.trigger) == [.recovery])
    }

    @Test("reports skips corrupted rows and counts them")
    func countsCorruptRows() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil
        ))
        try insertRunRow(
            runID: UUID(),
            transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            into: container
        )

        let page = try await store.reports(matching: RunReportQuery())

        #expect(page.records.count == 1)
        #expect(page.skippedCorruptedCount == 1)
    }
}

private func runPayload(runID: RunID, in container: ModelContainer) throws -> Data {
    let context = ModelContext(container)
    let rawID = runID.rawValue
    var descriptor = FetchDescriptor<PersistedRunRecord>(
        predicate: #Predicate { $0.runID == rawID }
    )
    descriptor.fetchLimit = 1
    return try #require(context.fetch(descriptor).first).transitionsData
}

private func runSchema(includesItems: Bool) -> Schema {
    var models: [any PersistentModel.Type] = [
        PersistedTrack.self,
        PersistedChangeLogEntry.self,
        PersistedMetricsSnapshot.self,
        PersistedPendingAlbumEntry.self,
        PersistedPendingVerificationMetadata.self,
        PersistedRunRecord.self,
        PersistedFixPlan.self,
        PersistedFixPlanDecision.self,
    ]
    if includesItems {
        models.append(PersistedRunWorkItem.self)
    }
    return Schema(models)
}
