import Core
import Foundation
import Testing
@testable import Services

@Suite("Work item persistence", .serialized)
struct WorkItemStoreTests {
    @Test("Run records round-trip work items")
    func roundTripsWorkItems() async throws {
        let store = try makeRunStore()
        let workItems = [makeWorkItem(state: .outcome(.written))]
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 102),
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(intent: .writeFixes, workItems: workItems)
        )

        try await store.upsert(record)

        #expect(try await store.loadAll() == [record])
        #expect(try await store.record(for: record.runID)?.workItems == workItems)
    }

    @Test("Configuration payloads load without work items")
    func loadsConfigurationPayload() async throws {
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
        let payload = WorklessPayload(
            version: RunRecordPayload.configurationVersion,
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .completedNoOp, timestamp: finishedAt)
            ],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(payload),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                state: .completedNoOp,
                startedAt: startedAt,
                finishedAt: finishedAt
            ),
            into: container
        )

        let record = try await RunRecordDataStore(modelContainer: container).loadAll().first

        #expect(record?.workItems.isEmpty == true)
    }

    @Test("Legacy payloads ignore unversioned work items")
    func ignoresLegacyWorkItems() async throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 101)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .completedNoOp, timestamp: finishedAt)
        ]
        let payloads = try [
            JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.legacyVersion,
                transitions: transitions,
                workItems: [makeWorkItem(state: .outcome(.written))],
                configuration: nil
            )),
            JSONEncoder().encode(ItemPayload(
                version: RunRecordPayload.configurationVersion,
                transitions: transitions,
                workItems: [makeWorkItem(state: .outcome(.written))],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            ))
        ]

        for payload in payloads {
            let container = try ModelContainerFactory.createInMemory()
            try insertRunRow(
                runID: UUID(),
                transitionsData: payload,
                input: RunRowInput(
                    scopeData: JSONEncoder().encode(scope),
                    state: .completedNoOp,
                    startedAt: startedAt,
                    finishedAt: finishedAt
                ),
                into: container
            )

            let record = try await RunRecordDataStore(modelContainer: container).loadAll().first

            #expect(record?.workItems.isEmpty == true)
        }
    }

    @Test("Work item payloads require work items")
    func rejectsMissingWorkItems() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .completedNoOp, timestamp: startedAt.addingTimeInterval(1))
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(WorklessPayload(
                version: RunRecordPayload.workItemVersion,
                transitions: transitions,
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                state: .completedNoOp,
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(1)
            ),
            into: container
        )

        await assertCorruptedRunField(
            store: RunRecordDataStore(modelContainer: container),
            expectedName: "workItems",
            expectedRunID: runID
        )
    }

    @Test("Terminal run work items are immutable")
    func rejectsTerminalMutation() async throws {
        let store = try makeRunStore()
        let itemID = UUID()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 102),
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                workItems: [makeWorkItem(id: itemID, state: .outcome(.written))]
            )
        )
        let replacement = replacing(
            initial,
            workItems: [makeWorkItem(id: itemID, state: .outcome(.failed))]
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(replacement)
            Issue.record("Expected terminal work item mutation to fail")
        } catch let RunRecordPersistenceError.invalidField(name, runID) {
            #expect(name == "workItems")
            #expect(runID == initial.runID.rawValue)
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }
}

private struct WorklessPayload: Encodable {
    let version: Int
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig
}

struct ItemPayload: Encodable {
    let version: Int
    let transitions: [RunLifecycleTransition]
    let workItems: [RunWorkItem]
    let configuration: RunConfig?
}

func makeWorkItem(id: UUID = UUID(), state: WorkState) -> RunWorkItem {
    RunWorkItem(
        id: id,
        target: .track(FixPlanItemIdentity(
            readID: "music-kit-1",
            appleScriptID: "persistent-1",
            artist: "Artist",
            album: "Album",
            trackName: "Track"
        )),
        change: WorkChange(
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 92,
            source: "MusicBrainz"
        ),
        state: state
    )
}

private func replacing(_ record: RunRecord, workItems: [RunWorkItem]) -> RunRecord {
    RunRecord(
        runID: record.runID,
        requestID: record.requestID,
        trigger: record.trigger,
        intent: record.intent,
        scope: record.scope,
        configuration: record.configuration,
        writeTarget: record.writeTarget,
        recoveryID: record.recoveryID,
        transitions: record.transitions,
        workItems: workItems,
        syncSummary: record.syncSummary,
        writeSummary: record.writeSummary,
        failureMessage: record.failureMessage,
        startedAt: record.startedAt,
        finishedAt: record.finishedAt
    )
}
