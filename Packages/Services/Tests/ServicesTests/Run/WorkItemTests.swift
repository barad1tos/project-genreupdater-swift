import Core
import Foundation
import Testing
@testable import Services

@Suite("Run work items")
struct WorkItemTests {
    @Test("Progress remains separate from explicit outcomes")
    func separatesProgressFromOutcomes() throws {
        let outcomes: [WorkOutcome] = [
            .noFixNeeded,
            .fixProposed,
            .written,
            .needsReview,
            .skipped,
            .failed,
            .deferred,
            .dismissed
        ]
        let states: [WorkState] = [
            .prepared,
            .attempting,
            .attempted,
            .outcome(.written)
        ]

        #expect(WorkOutcome.allCases.map(\.rawValue) == [
            "noFixNeeded",
            "fixProposed",
            "written",
            "needsReview",
            "skipped",
            "failed",
            "deferred",
            "dismissed"
        ])
        #expect(try JSONDecoder().decode([WorkOutcome].self, from: JSONEncoder().encode(outcomes)) == outcomes)
        #expect(try JSONDecoder().decode([WorkState].self, from: JSONEncoder().encode(states)) == states)
    }

    @Test("Album work preserves canonical album identity")
    func capturesAlbumWork() {
        let id = UUID()
        let identity = AlbumIdentity(artist: "Artist", album: "Album")

        let work = RunWorkItem(
            id: id,
            target: .album(identity),
            change: WorkChange(
                changeType: .yearUpdate,
                oldValue: nil,
                newValue: "2024",
                confidence: 87,
                source: "MusicBrainz"
            )
        )

        #expect(work.id == id)
        #expect(work.target == .album(identity))
        #expect(work.change.changeType == .yearUpdate)
        #expect(work.change.oldValue == nil)
        #expect(work.change.newValue == "2024")
        #expect(work.change.confidence == 87)
        #expect(work.change.source == "MusicBrainz")
        #expect(work.state == .prepared)
        #expect(work.detail == nil)
    }

    @Test("Terminal work preserves state and detail")
    func roundTripsTerminalWork() throws {
        let work = RunWorkItem(
            id: UUID(),
            target: .album(AlbumIdentity(artist: "Artist", album: "Album")),
            change: WorkChange(
                changeType: .yearUpdate,
                oldValue: nil,
                newValue: "2024",
                confidence: 87,
                source: "MusicBrainz"
            ),
            state: .outcome(.failed),
            detail: "Verification failed: année 2024"
        )

        let encoded = try JSONEncoder().encode(work)
        let decoded = try JSONDecoder().decode(RunWorkItem.self, from: encoded)

        #expect(decoded == work)
        #expect(decoded.state == .outcome(.failed))
        #expect(decoded.detail == "Verification failed: année 2024")
    }

    @Test("Track work captures the immutable fix plan item")
    func capturesTrackWork() {
        let item = FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "music-kit-1",
                appleScriptID: "persistent-1",
                artist: "Artist",
                album: "Album",
                trackName: "Track"
            ),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 92,
            source: "MusicBrainz"
        )

        let work = RunWorkItem(item: item)

        #expect(work.id == item.id)
        #expect(work.target == .track(item.identity))
        #expect(work.change.changeType == item.changeType)
        #expect(work.change.oldValue == item.oldValue)
        #expect(work.change.newValue == item.newValue)
        #expect(work.change.confidence == item.confidence)
        #expect(work.change.source == item.source)
        #expect(work.state == .prepared)
        #expect(work.detail == nil)
    }

    @Test("Write checkpoints advance through every durable boundary")
    func advancesWriteCheckpoints() throws {
        let work = makeWorkItem(state: .prepared)

        let attempting = try work.transition(to: .attempting)
        let attempted = try attempting.transition(to: .attempted)
        let written = try attempted.transition(to: .outcome(.written))

        #expect(attempting.state == .attempting)
        #expect(attempted.state == .attempted)
        #expect(written.state == .outcome(.written))
        #expect(written.id == work.id)
        #expect(written.target == work.target)
        #expect(written.change == work.change)
    }

    @Test("Write checkpoints reject skipped durable boundaries")
    func rejectsSkippedCheckpoint() {
        let work = makeWorkItem(state: .prepared)

        #expect(throws: WorkStateError.self) {
            try work.transition(to: .attempted)
        }
    }

    @Test("A known pre-dispatch failure can close an attempting item")
    func closesPreDispatchFailure() throws {
        let attempting = try makeWorkItem(state: .prepared).transition(to: .attempting)

        let failed = try attempting.transition(to: .outcome(.failed))

        #expect(failed.state == .outcome(.failed))
        #expect(throws: WorkStateError.self) {
            try attempting.transition(to: .outcome(.written))
        }
    }

    @Test("A batch checkpoint advances all matching work items atomically")
    func appliesBatchCheckpoint() throws {
        let first = makeWorkItem(state: .prepared)
        let second = makeWorkItem(state: .prepared)
        let lifecycle = makeLifecycle(workItems: [first, second])

        let next = try lifecycle.applying(.beforeAttempt([first.id, second.id]))

        #expect(next.workItems.map(\.state) == [.attempting, .attempting])
        #expect(lifecycle.workItems.map(\.state) == [.prepared, .prepared])
    }

    @Test("A batch checkpoint rejects unknown work without partial updates")
    func rejectsUnknownCheckpointWork() {
        let work = makeWorkItem(state: .prepared)
        let lifecycle = makeLifecycle(workItems: [work])

        #expect(throws: WorkCheckpointError.self) {
            try lifecycle.applying(.beforeAttempt([work.id, UUID()]))
        }
        #expect(lifecycle.workItems.map(\.state) == [.prepared])
    }

    @Test("Write checkpoints require captured write authority")
    func requiresWriteAuthority() {
        let work = makeWorkItem(state: .prepared)
        let lifecycle = makeLifecycle(workItems: [work], writeAuthority: .readOnly)

        #expect(throws: WorkCheckpointError.self) {
            try lifecycle.applying(.beforeAttempt([work.id]))
        }
        #expect(lifecycle.workItems.map(\.state) == [.prepared])
    }

    @Test("run records keep ordered workItems JSON")
    func encodesWorkItems() throws {
        let items = [makeWorkItem(state: .prepared), makeWorkItem(state: .prepared)]
        let lifecycle = makeLifecycle(workItems: items)
        let record = RunRecord(
            lifecycle: lifecycle,
            transitions: [RunLifecycleTransition(state: .writing, timestamp: lifecycle.startedAt)],
            syncSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )

        let data = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedItems = try #require(object["workItems"] as? [Any])
        let decoded = try JSONDecoder().decode(RunRecord.self, from: data)

        #expect(encodedItems.count == 2)
        #expect(decoded == record)
        #expect(decoded.workItems == items)
    }

    @Test("run records without workItems decode as empty")
    func decodesMissingItems() throws {
        let lifecycle = makeLifecycle(workItems: [makeWorkItem(state: .prepared)])
        let record = RunRecord(
            lifecycle: lifecycle,
            transitions: [RunLifecycleTransition(state: .writing, timestamp: lifecycle.startedAt)],
            syncSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "workItems")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RunRecord.self, from: legacyData)

        #expect(decoded.workItems.isEmpty)
    }

    private func makeLifecycle(
        workItems: [RunWorkItem],
        writeAuthority: WriteAuthority = .reviewedPlan
    ) -> RunLifecycleSnapshot {
        let capturedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 2,
            createdAt: capturedAt,
            reason: "work-checkpoint-test"
        )
        let input = FixPlanWriteInput(
            target: writeTarget(),
            scope: scope,
            configuration: makeRunConfiguration(
                scopeID: scope.id,
                capturedAt: capturedAt,
                writeAuthority: writeAuthority
            ),
            workItems: workItems
        )
        return RunLifecycleSnapshot(
            runID: RunID(),
            request: .manualWrite(input: input),
            scope: scope,
            startedAt: capturedAt,
            phase: .active(.writing)
        )
    }
}
