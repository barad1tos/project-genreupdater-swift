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
        let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let decoded = try JSONDecoder().decode(RunWorkItem.self, from: encoded)

        #expect(payload["writeChange"] == nil)
        #expect(decoded == work)
        #expect(decoded.writeChange == nil)
        #expect(decoded.state == .outcome(.failed))
        #expect(decoded.detail == "Verification failed: année 2024")
    }

    @Test("Prepared work rejects persisted write evidence")
    func rejectsPreparedEvidence() throws {
        let prepared = makeWorkItem(state: .prepared)
        var preparedPayload = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any]
        )
        preparedPayload["writeChange"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(prepared.change)
        )
        let corrupted = try JSONSerialization.data(withJSONObject: preparedPayload)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RunWorkItem.self, from: corrupted)
        }
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
        #expect(written.writeChange == work.change)
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

    @Test("Child hydration preserves terminal outcome identity")
    func rejectsOutcomeReplacement() {
        #expect(WorkState.outcome(.written).canFollow(.prepared))
        #expect(WorkState.outcome(.written).canFollow(.attempting))
        #expect(WorkState.outcome(.written).canFollow(.attempted))
        #expect(WorkState.outcome(.written).canFollow(.outcome(.written)))
        #expect(!WorkState.outcome(.failed).canFollow(.outcome(.written)))
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

    @Test("Run record checkpoints require writing state")
    func recordRequiresWriting() {
        let work = makeWorkItem(state: .prepared)
        let writing = makeLifecycle(workItems: [work])
        let recoverable = writing.requiringRecovery()
        let record = RunRecord(
            lifecycle: recoverable,
            transitions: [
                RunLifecycleTransition(state: .writing, timestamp: writing.startedAt),
                RunLifecycleTransition(state: .recoverable, timestamp: writing.startedAt),
            ],
            syncSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )

        #expect(throws: WorkCheckpointError.self) {
            try record.applying(.beforeAttempt([work.id]))
        }
        #expect(record.workItems.first?.state == .prepared)
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

    @Test("subset dismissal closes chosen items with detail and timestamp")
    func dismissesSelectedItems() throws {
        let prepared = makeWorkItem(state: .prepared)
        let attempted = makeWorkItem(state: .attempted)
        let untouched = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([prepared, attempted, untouched])
        let dismissedAt = Date(timeIntervalSince1970: 500)

        let updated = try ledger.dismissingItems(
            [prepared.id, attempted.id],
            detail: "Dismissed by user: duplicate release",
            at: dismissedAt
        )

        let byID = Dictionary(uniqueKeysWithValues: updated.items.map { ($0.id, $0) })
        #expect(byID[prepared.id]?.state == .outcome(.dismissed))
        #expect(byID[attempted.id]?.state == .outcome(.dismissed))
        #expect(byID[prepared.id]?.detail == "Dismissed by user: duplicate release")
        #expect(byID[prepared.id]?.dismissedAt == dismissedAt)
        #expect(byID[attempted.id]?.dismissedAt == dismissedAt)
        #expect(byID[untouched.id] == untouched)
    }

    @Test("dismissing an unknown item is rejected")
    func rejectsUnknownDismissal() {
        let ledger = WorkLedger([makeWorkItem(state: .prepared)])

        #expect(throws: WorkCheckpointError.self) {
            try ledger.dismissingItems([UUID()], detail: "Dismissed by user: x", at: Date(timeIntervalSince1970: 500))
        }
    }

    @Test("dismissing a written item is rejected")
    func rejectsTerminalDismissal() {
        let written = makeWorkItem(state: .outcome(.written))
        let ledger = WorkLedger([written])

        #expect(throws: WorkCheckpointError.self) {
            try ledger.dismissingItems(
                [written.id],
                detail: "Dismissed by user: x",
                at: Date(timeIntervalSince1970: 500)
            )
        }
    }

    @Test("legacy work items without dismissedAt decode as undismissed")
    func decodesMissingDismissedAt() throws {
        let item = makeWorkItem(state: .prepared)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        object.removeValue(forKey: "dismissedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RunWorkItem.self, from: legacyData)

        #expect(decoded.dismissedAt == nil)
    }

    @Test("grouped dismissal of prepared work keeps the record open")
    func groupedDismissalKeepsRecordOpen() throws {
        let first = makeWorkItem(state: .prepared)
        let second = makeWorkItem(state: .prepared)
        let record = makeOpenRecoveryRecord(workItems: [first, second])
        let dismissedAt = Date(timeIntervalSince1970: 500)

        let updated = try record.dismissingWork(
            ids: [first.id],
            reason: "duplicate release",
            at: dismissedAt
        )

        let byID = Dictionary(uniqueKeysWithValues: updated.workItems.map { ($0.id, $0) })
        #expect(updated.finishedAt == nil)
        #expect(byID[first.id]?.state == .outcome(.dismissed))
        #expect(byID[first.id]?.detail == "Dismissed by user: duplicate release")
        #expect(byID[first.id]?.dismissedAt == dismissedAt)
        #expect(byID[second.id]?.state == .prepared)
    }

    @Test("grouped dismissal cannot cover write-uncertain items")
    func groupedDismissalRejectsUncertain() throws {
        let prepared = makeWorkItem(state: .prepared)
        let attempted = makeWorkItem(state: .attempted)
        let record = makeOpenRecoveryRecord(workItems: [prepared, attempted])

        #expect(throws: WorkCheckpointError.self) {
            try record.dismissingWork(
                ids: [prepared.id, attempted.id],
                reason: "cleanup",
                at: Date(timeIntervalSince1970: 500)
            )
        }
    }

    @Test("individual dismissal of an uncertain item is an explicit decision")
    func individualDismissalAllowsUncertain() throws {
        let attempted = makeWorkItem(state: .attempted)
        let record = makeOpenRecoveryRecord(workItems: [attempted])
        let dismissedAt = Date(timeIntervalSince1970: 500)

        let updated = try record.dismissingUncertainWork(
            id: attempted.id,
            reason: "verified manually in Music.app",
            at: dismissedAt
        )

        let item = try #require(updated.workItems.first)
        #expect(item.state == .outcome(.dismissed))
        #expect(item.detail == "Dismissed without verification by user decision: verified manually in Music.app")
        #expect(item.dismissedAt == dismissedAt)
        #expect(updated.finishedAt == nil)
    }

    @Test("individual dismissal also covers certain open items")
    func individualDismissalCoversPrepared() throws {
        let prepared = makeWorkItem(state: .prepared)
        let record = makeOpenRecoveryRecord(workItems: [prepared])

        let updated = try record.dismissingUncertainWork(
            id: prepared.id,
            reason: "not wanted",
            at: Date(timeIntervalSince1970: 500)
        )

        let item = try #require(updated.workItems.first)
        #expect(item.state == .outcome(.dismissed))
        #expect(item.detail == "Dismissed by user: not wanted")
    }

    @Test("individual dismissal acknowledges an evidence-less legacy no-op without rewriting its outcome")
    func individualDismissalAcknowledgesLegacyNoOp() async throws {
        let store = try makeRunStore()
        let legacyNoOp = makeWorkItem(state: .outcome(.noFixNeeded))
        let record = try makeOpenRecoveryRecord(workItems: [legacyNoOp])
            .recordingRecoveryObservationBlocker(
                RecoveryObservationBlocker(itemID: legacyNoOp.id, issue: .trackMissing)
            )
        try await store.upsert(record)
        let acknowledgedAt = Date(timeIntervalSince1970: 500)

        let updated = try record.dismissingUncertainWork(
            id: legacyNoOp.id,
            reason: "track is no longer available",
            at: acknowledgedAt
        )
        try await store.upsert(updated)

        let reloaded = try #require(await store.record(for: record.runID))
        let item = try #require(reloaded.workItems.first)
        #expect(item.state == .outcome(.noFixNeeded))
        #expect(item.detail == "Acknowledged by user; mirror left unchanged: track is no longer available")
        #expect(item.dismissedAt == acknowledgedAt)
        #expect(item.recoveryObservationIssue == nil)
        #expect(!reloaded.requiresRecoveryObservation)
    }

    @Test("dismissed subsets survive the store roundtrip on open records")
    func dismissalPersistsOnOpenRecord() async throws {
        let store = try makeRunStore()
        let first = makeWorkItem(state: .prepared)
        let second = makeWorkItem(state: .prepared)
        let record = makeOpenRecoveryRecord(workItems: [first, second])
        try await store.upsert(record)
        let dismissedAt = Date(timeIntervalSince1970: 500)

        let updated = try record.dismissingWork(ids: [first.id], reason: "duplicate", at: dismissedAt)
        try await store.upsert(updated)

        let reloaded = try #require(await store.record(for: record.runID))
        let byID = Dictionary(uniqueKeysWithValues: reloaded.workItems.map { ($0.id, $0) })
        #expect(byID[first.id]?.state == .outcome(.dismissed))
        #expect(byID[first.id]?.dismissedAt == dismissedAt)
        #expect(byID[second.id]?.state == .prepared)
        #expect(reloaded.finishedAt == nil)
    }

    @Test("re-dismissing an already-dismissed item is rejected in memory")
    func rejectsRepeatedDismissal() throws {
        let prepared = makeWorkItem(state: .prepared)
        let record = makeOpenRecoveryRecord(workItems: [prepared])
        let dismissed = try record.dismissingWork(
            ids: [prepared.id],
            reason: "duplicate",
            at: Date(timeIntervalSince1970: 500)
        )

        #expect(throws: WorkCheckpointError.self) {
            try dismissed.dismissingWork(
                ids: [prepared.id],
                reason: "changed my mind",
                at: Date(timeIntervalSince1970: 900)
            )
        }
        let item = try #require(dismissed.workItems.first)
        #expect(item.detail == "Dismissed by user: duplicate")
        #expect(item.dismissedAt == Date(timeIntervalSince1970: 500))
    }

    @Test("dismissal is rejected while the write run is still active")
    func rejectsDismissalOnActiveRun() throws {
        let prepared = makeWorkItem(state: .prepared)
        let attempted = makeWorkItem(state: .attempted)
        let lifecycle = makeLifecycle(workItems: [prepared, attempted])
        let active = RunRecord(
            lifecycle: lifecycle,
            transitions: [RunLifecycleTransition(state: .writing, timestamp: lifecycle.startedAt)],
            syncSummary: nil,
            failureMessage: nil,
            finishedAt: nil
        )

        #expect(throws: WorkCheckpointError.self) {
            try active.dismissingWork(ids: [prepared.id], reason: "cleanup", at: Date(timeIntervalSince1970: 500))
        }
        #expect(throws: WorkCheckpointError.self) {
            try active.dismissingUncertainWork(
                id: attempted.id,
                reason: "cleanup",
                at: Date(timeIntervalSince1970: 500)
            )
        }
    }

    @Test("grouped dismissal rejects attempting items")
    func groupedDismissalRejectsAttempting() throws {
        let prepared = makeWorkItem(state: .prepared)
        let attempting = makeWorkItem(state: .attempting)
        let record = makeOpenRecoveryRecord(workItems: [prepared, attempting])

        #expect(throws: WorkCheckpointError.self) {
            try record.dismissingWork(
                ids: [prepared.id, attempting.id],
                reason: "cleanup",
                at: Date(timeIntervalSince1970: 500)
            )
        }
    }

    @Test("individual dismissal marks attempting items as unverified decisions")
    func individualDismissalMarksAttempting() throws {
        let attempting = makeWorkItem(state: .attempting)
        let record = makeOpenRecoveryRecord(workItems: [attempting])

        let updated = try record.dismissingUncertainWork(
            id: attempting.id,
            reason: "checked manually",
            at: Date(timeIntervalSince1970: 500)
        )

        let item = try #require(updated.workItems.first)
        #expect(item.detail == "Dismissed without verification by user decision: checked manually")
    }

    @Test("a dismissal stamp on a non-dismissed closure is rejected by the store")
    func rejectsStampOnOtherClosure() async throws {
        let store = try makeRunStore()
        let item = makeWorkItem(state: .prepared)
        var input = RunRecordInput(
            intent: .writeFixes,
            workItems: [item],
            includesSyncTransition: false
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: input
        )
        try await store.upsert(record)
        input.runID = record.runID
        input.requestID = record.requestID
        input.scope = record.scope
        input.configuration = record.configuration
        input.workItems = [RunWorkItem(
            id: item.id,
            target: item.target,
            change: item.change,
            state: .outcome(.failed),
            detail: item.detail,
            dismissedAt: Date(timeIntervalSince1970: 500)
        )]
        let mutated = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: input
        )

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(mutated)
        }
    }

    @Test("a dismissal that tampers with the change payload is rejected")
    func rejectsTamperedDismissal() async throws {
        let store = try makeRunStore()
        let item = makeWorkItem(state: .prepared)
        var input = RunRecordInput(
            intent: .writeFixes,
            workItems: [item],
            includesSyncTransition: false
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: input
        )
        try await store.upsert(record)
        input.runID = record.runID
        input.requestID = record.requestID
        input.scope = record.scope
        input.configuration = record.configuration
        input.workItems = [RunWorkItem(
            id: item.id,
            target: item.target,
            change: WorkChange(
                changeType: item.change.changeType,
                oldValue: item.change.oldValue,
                newValue: "Tampered",
                confidence: item.change.confidence,
                source: item.change.source
            ),
            state: .outcome(.dismissed),
            detail: "Dismissed by user: cover story",
            dismissedAt: Date(timeIntervalSince1970: 500)
        )]
        let mutated = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: input
        )

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(mutated)
        }
    }

    @Test("a stored dismissal timestamp can never be re-stamped")
    func rejectsDismissalRestamp() async throws {
        let store = try makeRunStore()
        let item = makeWorkItem(state: .prepared)
        let record = makeOpenRecoveryRecord(workItems: [item])
        try await store.upsert(record)
        let dismissed = try record.dismissingWork(
            ids: [item.id],
            reason: "duplicate",
            at: Date(timeIntervalSince1970: 500)
        )
        try await store.upsert(dismissed)
        let restamped = try record.dismissingWork(
            ids: [item.id],
            reason: "duplicate",
            at: Date(timeIntervalSince1970: 900)
        )

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(restamped)
        }
    }

    private func makeOpenRecoveryRecord(workItems: [RunWorkItem]) -> RunRecord {
        let lifecycle = makeLifecycle(workItems: workItems)
        return RunRecord(
            lifecycle: lifecycle,
            transitions: [
                RunLifecycleTransition(state: .writing, timestamp: lifecycle.startedAt),
                RunLifecycleTransition(state: .recoverable, timestamp: lifecycle.startedAt),
            ],
            syncSummary: nil,
            failureMessage: "Unknown write outcome",
            finishedAt: nil
        )
    }

    @Test("continuable work keeps only failed and skipped outcomes in order")
    func derivesContinuableWork() {
        let written = makeWorkItem(state: .outcome(.written))
        let failed = makeWorkItem(state: .outcome(.failed))
        let dismissed = makeWorkItem(state: .outcome(.dismissed))
        let skipped = makeWorkItem(state: .outcome(.skipped))
        let needsReview = makeWorkItem(state: .outcome(.needsReview))
        let lifecycle = makeLifecycle(workItems: [written, failed, dismissed, skipped, needsReview])
        let record = RunRecord(
            lifecycle: lifecycle,
            transitions: [
                RunLifecycleTransition(state: .writing, timestamp: lifecycle.startedAt),
                RunLifecycleTransition(state: .cancelled, timestamp: lifecycle.startedAt),
            ],
            syncSummary: nil,
            failureMessage: nil,
            finishedAt: lifecycle.startedAt
        )

        // Written landed, dismissed is a user decision, needsReview must be
        // reviewed before any re-application — only failed and skipped remain.
        #expect(record.continuableWork.map(\.id) == [failed.id, skipped.id])
    }

    @Test("unresolved evidence covers review, deferral, and continuable work")
    func derivesUnresolvedEvidence() {
        let startedAt = Date(timeIntervalSince1970: 100)
        func record(
            intent: RunIntent = .writeFixes,
            target: FixPlanWriteTarget? = writeTarget(),
            items: [RunWorkItem]
        ) -> RunRecord {
            makeRunRecord(
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(10),
                state: .cancelled,
                syncSummary: nil,
                input: RunRecordInput(
                    intent: intent,
                    writeTarget: target,
                    workItems: items,
                    includesSyncTransition: false
                )
            )
        }

        #expect(record(items: [makeWorkItem(state: .outcome(.needsReview))]).hasUnresolvedEvidence)
        #expect(record(items: [makeWorkItem(state: .outcome(.deferred))]).hasUnresolvedEvidence)
        #expect(record(items: [makeWorkItem(state: .outcome(.failed))]).hasUnresolvedEvidence)
        #expect(!record(target: nil, items: [makeWorkItem(state: .outcome(.failed))]).hasUnresolvedEvidence)
        #expect(!record(items: [makeWorkItem(state: .outcome(.written))]).hasUnresolvedEvidence)
        #expect(!record(
            intent: .observeLibrary,
            items: [makeWorkItem(state: .outcome(.failed))]
        ).hasUnresolvedEvidence)
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
            admission: processingAdmission(scope: scope),
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
