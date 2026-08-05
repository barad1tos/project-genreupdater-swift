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

        #expect(retained == [planA.rawValue, planB.rawValue])
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

    @Test("plans outside the keeping set are deleted with their decisions")
    func deletePlansRemovesOrphansWithDecisions() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let planStore = FixPlanDataStore(modelContainer: container)
        let kept = makePlan()
        let orphan = makePlan()
        try await planStore.savePlan(kept, initialDecision: FixPlanReviewer.initialDecision(for: kept, at: baseDate))
        try await planStore.savePlan(
            orphan,
            initialDecision: FixPlanReviewer.initialDecision(for: orphan, at: baseDate)
        )

        let deleted = try await planStore.deletePlans(notIn: [kept.id.rawValue])

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
        let current = makePlan()
        let queued = makePlan()
        try await planStore.savePlan(
            current,
            initialDecision: FixPlanReviewer.initialDecision(for: current, at: baseDate)
        )
        try await planStore.savePlan(
            queued,
            initialDecision: FixPlanReviewer.initialDecision(for: queued, at: baseDate)
        )

        let deleted = try await planStore.deletePlans(notIn: [current.id.rawValue, queued.id.rawValue])

        #expect(deleted == 0)
        #expect(try await planStore.plan(id: current.id, revision: current.revision) != nil)
        #expect(try await planStore.plan(id: queued.id, revision: queued.revision) != nil)
    }

    @Test("a plan referenced only by a pruned run is deleted; a retained run's plan survives")
    func prunedRunOrphansItsPlan() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runStore = RunRecordDataStore(modelContainer: container)
        let planStore = FixPlanDataStore(modelContainer: container)
        let oldPlan = makePlan()
        let newPlan = makePlan()
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

    private func makePlan() -> FixPlan {
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
        return FixPlan(
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
            items: [item]
        )
    }
}
