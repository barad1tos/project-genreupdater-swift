import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run report items")
struct RunReportItemTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("terminal upsert writes one report row per work item")
    func terminalUpsertWritesReportRows() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let trackItem = makeWorkItem(state: .outcome(.written))
        let albumItem = RunWorkItem(
            id: UUID(),
            target: .album(AlbumIdentity(artist: "Album Artist", album: "Album Title")),
            change: WorkChange(
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 88,
                source: "Discogs"
            ),
            state: .outcome(.needsReview)
        )
        let record = terminalWriteRecord(at: 0, items: [trackItem, albumItem])
        try await store.upsert(record)

        let rows = try fetchReportRows(container)

        #expect(rows.count == 2)
        let trackRow = try #require(rows.first { $0.itemID == trackItem.id })
        #expect(trackRow.key == "\(record.runID.rawValue.uuidString):\(trackItem.id.uuidString)")
        #expect(trackRow.runID == record.runID.rawValue)
        #expect(trackRow.position == 0)
        #expect(trackRow.runStartedAt == record.startedAt)
        #expect(trackRow.changeTypeRaw == ChangeType.genreUpdate.rawValue)
        #expect(trackRow.stateRaw == "outcome:written")
        #expect(trackRow.artist == "Artist")
        #expect(trackRow.album == "Album")
        #expect(trackRow.trackName == "Track")
        #expect(try JSONDecoder().decode(RunWorkItem.self, from: trackRow.itemData) == trackItem)

        let albumRow = try #require(rows.first { $0.itemID == albumItem.id })
        #expect(albumRow.position == 1)
        #expect(albumRow.changeTypeRaw == ChangeType.yearUpdate.rawValue)
        #expect(albumRow.stateRaw == "outcome:needsReview")
        #expect(albumRow.artist == "Album Artist")
        #expect(albumRow.album == "Album Title")
        #expect(albumRow.trackName.isEmpty)
        #expect(try JSONDecoder().decode(RunWorkItem.self, from: albumRow.itemData) == albumItem)
    }

    @Test("open upsert writes no report rows")
    func openUpsertWritesNoReportRows() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let record = makeRunRecord(
            startedAt: baseDate,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                workItems: [makeWorkItem(state: .prepared)],
                includesSyncTransition: false
            )
        )
        try await store.upsert(record)

        let rows = try fetchReportRows(container)

        #expect(rows.isEmpty)
    }

    @Test("re-upserting the same terminal record does not duplicate rows")
    func terminalReUpsertDoesNotDuplicate() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let record = terminalWriteRecord(at: 0, items: [
            makeWorkItem(state: .outcome(.written)),
            makeWorkItem(state: .outcome(.failed)),
        ])
        try await store.upsert(record)
        try await store.upsert(record)

        let rows = try fetchReportRows(container)

        #expect(rows.count == 2)
    }

    @Test("rows appear when an open run closes, replacing checkpoint rows")
    func openRunClosureEmitsRowsAndDropsCheckpoints() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let item = makeWorkItem(state: .prepared)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: baseDate,
            reason: "manualCheck"
        )
        let input = RunRecordInput(
            intent: .writeFixes,
            writeTarget: writeTarget(),
            workItems: [item],
            scope: scope,
            configuration: makeRunConfiguration(
                scopeID: scope.id,
                capturedAt: baseDate,
                writeAuthority: .reviewedPlan
            ),
            includesSyncTransition: false
        )
        let open = makeRunRecord(
            startedAt: baseDate,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: input
        )
        try await store.upsert(open)
        #expect(try fetchReportRows(container).isEmpty)

        let dismissed = try item.transition(to: .outcome(.dismissed))
        try await store.upsert(closing(open, items: [dismissed], at: baseDate.addingTimeInterval(5)))

        let rows = try fetchReportRows(container)
        let row = try #require(rows.first)
        let checkpointRows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunWorkItem>())
        #expect(rows.count == 1)
        #expect(row.stateRaw == "outcome:dismissed")
        #expect(try JSONDecoder().decode(RunWorkItem.self, from: row.itemData) == dismissed)
        #expect(checkpointRows.isEmpty)
    }

    @Test("terminal repair emits report rows")
    func terminalRepairEmitsReportRows() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 101)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let workItems = [makeWorkItem(state: .outcome(.written))]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .completed, timestamp: finishedAt),
                ],
                workItems: workItems,
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .completed,
                startedAt: startedAt
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: startedAt)

        let rows = try fetchReportRows(container)
        let row = try #require(rows.first)
        #expect(didClose)
        #expect(rows.count == 1)
        #expect(row.runID == runID)
        #expect(row.runStartedAt == startedAt)
        #expect(row.stateRaw == "outcome:written")
    }

    @Test("corrupted-row recovery emits report rows for the rebuilt ledger")
    func corruptedRecoveryEmitsReportRows() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let workItems = [
            makeWorkItem(state: .outcome(.written)),
            makeWorkItem(state: .outcome(.failed)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(
                        state: .recoverable,
                        timestamp: startedAt.addingTimeInterval(1)
                    ),
                ],
                workItems: workItems,
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                rawIntent: "invalid",
                state: .recoverable,
                startedAt: startedAt
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let didClose = try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date())

        let rows = try fetchReportRows(container)
        #expect(didClose)
        #expect(rows.count == 2)
        let states = Set(rows.map(\.stateRaw))
        #expect(states == ["outcome:written", "outcome:failed"])
    }

    @Test("prune deletes report rows of pruned runs and keeps retained ones")
    func pruneDeletesReportRowsOfPrunedRuns() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let oldest = terminalWriteRecord(at: 0, items: [makeWorkItem(state: .outcome(.written))])
        let middle = terminalWriteRecord(at: 1, items: [makeWorkItem(state: .outcome(.written))])
        let newest = terminalWriteRecord(at: 2, items: [makeWorkItem(state: .outcome(.written))])
        for record in [oldest, middle, newest] {
            try await store.upsert(record)
        }

        let deleted = try await store.prune(keepingLatest: 1)

        let rows = try fetchReportRows(container)
        #expect(deleted == 2)
        #expect(rows.count == 1)
        #expect(rows.first?.runID == newest.runID.rawValue)
    }

    private func terminalWriteRecord(at index: Int, items: [RunWorkItem]) -> RunRecord {
        let startedAt = baseDate.addingTimeInterval(Double(index) * 10)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                workItems: items,
                includesSyncTransition: false
            )
        )
    }

    private func fetchReportRows(_ container: ModelContainer) throws -> [PersistedRunReportItem] {
        try ModelContext(container).fetch(FetchDescriptor<PersistedRunReportItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
    }

    /// Appends the terminal transition to an open record's audit — the only
    /// legal way to close a run, since stored transitions are append-only.
    private func closing(_ open: RunRecord, items: [RunWorkItem], at finishedAt: Date) -> RunRecord {
        RunRecord(
            header: RunRecord.Header(
                runID: open.runID,
                requestID: open.requestID,
                trigger: open.trigger,
                intent: open.intent,
                scope: open.scope,
                continuesRunID: open.continuesRunID,
                startedAt: open.startedAt
            ),
            configuration: open.configuration,
            writeTarget: open.writeTarget,
            recoveryID: open.recoveryID,
            transitions: open.transitions + [
                RunLifecycleTransition(state: .cancelled, timestamp: finishedAt),
            ],
            workItems: items,
            status: RunRecord.Status(
                syncSummary: nil,
                writeSummary: nil,
                failureMessage: nil,
                finishedAt: finishedAt
            )
        )
    }
}
