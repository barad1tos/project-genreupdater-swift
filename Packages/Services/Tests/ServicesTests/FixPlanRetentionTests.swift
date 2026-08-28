import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Fix-plan retention")
struct FixPlanRetentionTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("retained plan IDs collect every persisted write target")
    func retainedPlanIDsCollectWriteTargets() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        let planA = FixPlanID()
        let planB = FixPlanID()
        try await runStore.upsert(writeRecord(at: 0, planID: planA))
        try await runStore.upsert(writeRecord(at: 1, planID: planB))
        try await runStore.upsert(makeRunRecord(
            startedAt: baseDate.addingTimeInterval(30),
            finishedAt: baseDate.addingTimeInterval(31),
            state: .completedNoOp,
            syncSummary: nil
        ))

        let retained = try await runStore.retainedPlanIDs()

        #expect(retained == [planA, planB])
    }

    @Test("an unreadable run payload fails plan retention closed")
    func retainedPlanIDsFailClosedOnUnreadableRow() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        try await runStore.upsert(writeRecord(at: 0, planID: FixPlanID()))
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

        let retained = try await runStore.retainedPlanIDs()

        #expect(retained == nil)
    }

    @Test("a rule-failing row with a decodable payload still names its plan")
    func ruleFailingRowNamesItsPlan() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        let planID = FixPlanID()
        let startedAt = baseDate
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: UUID(),
            transitionsData: JSONEncoder().encode(RunRecordPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .cancelled, timestamp: startedAt.addingTimeInterval(1)),
                ],
                workItems: [],
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                ),
                writeTarget: FixPlanWriteTarget(
                    planID: planID,
                    planRevision: .initial,
                    decisionRevision: .initial
                ),
                recoveryID: nil,
                continuesRunID: nil,
                writeSummary: nil
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                rawIntent: "invalid",
                state: .cancelled,
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(1)
            ),
            into: container
        )

        // Exactly the rows PR #137 protects (unresolved evidence): degrading
        // this branch to a skip would delete the plan behind an unresolved
        // recovery; degrading to fail-closed would silently stop retention.
        let retained = try await runStore.retainedPlanIDs()

        #expect(retained == [planID])
    }

    @Test("a partially corrupted payload's plan is salvaged per-field")
    func partiallyCorruptedPayloadPlanSalvaged() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        let planID = FixPlanID()
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: baseDate,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: UUID(),
            transitionsData: JSONEncoder().encode(MangledSummaryPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: baseDate),
                    RunLifecycleTransition(state: .cancelled, timestamp: baseDate.addingTimeInterval(1)),
                ],
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: baseDate,
                    writeAuthority: .reviewedPlan
                ),
                writeTarget: FixPlanWriteTarget(
                    planID: planID,
                    planRevision: .initial,
                    decisionRevision: .initial
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .cancelled,
                startedAt: baseDate,
                finishedAt: baseDate.addingTimeInterval(1)
            ),
            into: container
        )

        // The strict decode rejects the mangled writeSummary; the per-field
        // salvage still names the plan — retention must not fail closed here.
        let retained = try await runStore.retainedPlanIDs()

        #expect(retained == [planID])
    }

    @Test("a forward-schema row's plan reference is salvaged")
    func forwardSchemaRowPlanSalvaged() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        let planID = FixPlanID()
        try insertRunRow(
            runID: UUID(),
            transitionsData: JSONEncoder().encode(ForwardPlanPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: baseDate),
                    RunLifecycleTransition(state: .cancelled, timestamp: baseDate.addingTimeInterval(1)),
                ],
                writeTarget: FixPlanWriteTarget(
                    planID: planID,
                    planRevision: .initial,
                    decisionRevision: .initial
                )
            )),
            input: RunRowInput(
                state: .cancelled,
                startedAt: baseDate,
                finishedAt: baseDate.addingTimeInterval(1)
            ),
            into: container
        )

        let retained = try await runStore.retainedPlanIDs()

        #expect(retained == [planID])
    }

    @Test("plans outside the keeping set are deleted with their decisions")
    func deletePlansRemovesOrphansWithDecisions() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let planStore = FixPlanDataStore(modelContainer: container)
        let kept = try makePlan()
        let orphan = try makePlan()
        try await planStore.savePlan(kept, initialDecision: FixPlanReviewer.initialDecision(for: kept, at: baseDate))
        try await planStore.savePlan(
            orphan,
            initialDecision: FixPlanReviewer.initialDecision(for: orphan, at: baseDate)
        )

        let deleted = try await planStore.deletePlans(notIn: [kept.id])

        let context = ModelContext(container)
        let planRows = try context.fetch(FetchDescriptor<PersistedFixPlan>())
        let decisionRows = try context.fetch(FetchDescriptor<PersistedFixPlanDecision>())
        #expect(deleted == 1)
        #expect(planRows.map(\.planID) == [kept.id.rawValue])
        #expect(decisionRows.map(\.planID) == [kept.id.rawValue])
        #expect(try await planStore.plan(id: orphan.id, revision: orphan.revision) == nil)
    }

    @Test("every plan in the keeping set survives")
    func deletePlansKeepsKeepingSet() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let planStore = FixPlanDataStore(modelContainer: container)
        let current = try makePlan()
        let queued = try makePlan()
        try await planStore.savePlan(
            current,
            initialDecision: FixPlanReviewer.initialDecision(for: current, at: baseDate)
        )
        try await planStore.savePlan(
            queued,
            initialDecision: FixPlanReviewer.initialDecision(for: queued, at: baseDate)
        )

        let deleted = try await planStore.deletePlans(notIn: [current.id, queued.id])

        #expect(deleted == 0)
        #expect(try await planStore.plan(id: current.id, revision: current.revision) != nil)
        #expect(try await planStore.plan(id: queued.id, revision: queued.revision) != nil)
    }

    @Test("a plan referenced only by a pruned run is deleted; a retained run's plan survives")
    func prunedRunOrphansItsPlan() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        let planStore = FixPlanDataStore(modelContainer: container)
        let oldPlan = try makePlan()
        let newPlan = try makePlan()
        try await planStore.savePlan(
            oldPlan,
            initialDecision: FixPlanReviewer.initialDecision(for: oldPlan, at: baseDate)
        )
        try await planStore.savePlan(
            newPlan,
            initialDecision: FixPlanReviewer.initialDecision(for: newPlan, at: baseDate)
        )
        try await runStore.upsert(writeRecord(at: 0, planID: oldPlan.id))
        let retainedRun = writeRecord(at: 1, planID: newPlan.id)
        try await runStore.upsert(retainedRun)

        let pruned = try await runStore.prune(keepingLatest: 1)
        let retained = try #require(await runStore.retainedPlanIDs())
        let deleted = try await planStore.deletePlans(notIn: retained)

        #expect(pruned == 1)
        #expect(deleted == 1)
        #expect(try await planStore.plan(id: newPlan.id, revision: newPlan.revision) != nil)
        #expect(try await planStore.plan(id: oldPlan.id, revision: oldPlan.revision) == nil)
    }

    private struct ForwardPlanPayload: Encodable {
        let version = RunRecordPayload.currentVersion + 1
        let transitions: [RunLifecycleTransition]
        let writeTarget: FixPlanWriteTarget
    }

    private struct MangledSummaryPayload: Encodable {
        let version = RunRecordPayload.currentVersion
        let transitions: [RunLifecycleTransition]
        let configuration: RunConfig
        let writeTarget: FixPlanWriteTarget
        let writeSummary = "invalid"
    }

    private func writeRecord(at index: Int, planID: FixPlanID) -> RunRecord {
        let startedAt = baseDate.addingTimeInterval(Double(index) * 10)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: FixPlanWriteTarget(
                    planID: planID,
                    planRevision: .initial,
                    decisionRevision: .initial
                ),
                workItems: [makeWorkItem(state: .outcome(.written))],
                includesSyncTransition: false
            )
        )
    }

    private func makePlan() throws -> FixPlan {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: baseDate,
            reason: "manualCheck"
        )
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
        return try FixPlan(
            id: FixPlanID(),
            revision: .initial,
            sourceRunID: RunID(),
            createdAt: baseDate,
            configuration: FixPlanConfig(
                capturedAt: baseDate,
                appConfiguration: AppConfiguration(),
                options: UpdateOptions()
            ),
            scope: scope,
            admission: processingAdmission(scope: scope),
            items: [item]
        )
    }
}
