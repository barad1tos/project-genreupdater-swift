import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("FixPlanDataStore")
struct FixPlanDataTests {
    @Test("savePlan round-trips all fields including nested snapshot values")
    func savePlanRoundTripsAllFields() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))

        try await store.savePlan(plan, initialDecision: initial)
        let loaded = try await store.plan(id: plan.id, revision: plan.revision)

        #expect(loaded == plan)
        #expect(loaded?.configuration == plan.configuration)
        #expect(loaded?.configuration.appConfiguration.cleaning.genreMappings["Electronic"] == "Electronica")
        #expect(loaded?.scope == plan.scope)
        #expect(loaded?.items == plan.items)
        #expect(try await store.latestPlan() == plan)
    }

    @Test("savePlan persists the plan and its initial decision atomically")
    func savePlanPersistsPlanAndInitialDecisionAtomically() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))

        try await store.savePlan(plan, initialDecision: initial)
        let decision = try await store.currentDecision(for: plan.id)

        #expect(decision != nil)
        #expect(decision == initial)
    }

    @Test("savePlan throws duplicatePlan for an existing (planID, revision) pair")
    func savePlanDuplicateRevisionThrowsDuplicatePlan() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)

        do {
            try await store.savePlan(plan, initialDecision: initial)
            Issue.record("Expected savePlan to throw FixPlanPersistenceError.duplicatePlan")
        } catch let error as FixPlanPersistenceError {
            guard case let .duplicatePlan(planID, revision) = error else {
                Issue.record("Expected duplicatePlan, got \(error)")
                return
            }
            #expect(planID == plan.id.rawValue)
            #expect(revision == plan.revision.value)
        }

        #expect(try await store.plan(id: plan.id, revision: plan.revision) == plan)
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("savePlan allows a new revision of the same plan and resets the decision")
    func savePlanAllowsNewRevisionAndResetsDecision() async throws {
        let store = try makeStore()
        let planID = FixPlanID()
        let first = makePlan(id: planID, revision: .initial, createdAt: Date(timeIntervalSince1970: 100))
        let second = makePlan(id: planID, revision: FixPlanRevision(2), createdAt: Date(timeIntervalSince1970: 200))
        let firstInitial = FixPlanReviewer.initialDecision(for: first, at: Date(timeIntervalSince1970: 101))
        let secondInitial = FixPlanReviewer.initialDecision(for: second, at: Date(timeIntervalSince1970: 201))

        try await store.savePlan(first, initialDecision: firstInitial)
        try await store.savePlan(second, initialDecision: secondInitial)

        #expect(try await store.plan(id: planID, revision: first.revision) == first)
        #expect(try await store.plan(id: planID, revision: second.revision) == second)
        #expect(try await store.currentDecision(for: planID) == secondInitial)
    }

    @Test("plan(id:revision:) returns nil for an unknown pair")
    func planReturnsNilForUnknownPair() async throws {
        let store = try makeStore()
        let plan = makePlan()
        try await store.savePlan(plan, initialDecision: FixPlanReviewer.initialDecision(
            for: plan,
            at: Date(timeIntervalSince1970: 101)
        ))

        #expect(try await store.plan(id: FixPlanID(), revision: .initial) == nil)
        #expect(try await store.plan(id: plan.id, revision: FixPlanRevision(2)) == nil)
    }

    @Test("latestPlan returns the newest plan by createdAt")
    func latestPlanReturnsNewestByCreatedAt() async throws {
        let store = try makeStore()
        let older = makePlan(createdAt: Date(timeIntervalSince1970: 100))
        let newer = makePlan(createdAt: Date(timeIntervalSince1970: 200))
        try await store.savePlan(older, initialDecision: FixPlanReviewer.initialDecision(
            for: older,
            at: Date(timeIntervalSince1970: 101)
        ))
        try await store.savePlan(newer, initialDecision: FixPlanReviewer.initialDecision(
            for: newer,
            at: Date(timeIntervalSince1970: 201)
        ))

        #expect(try await store.latestPlan() == newer)
    }

    @Test("latestPlan returns nil when no plans are stored")
    func latestPlanReturnsNilWhenEmpty() async throws {
        let store = try makeStore()

        #expect(try await store.latestPlan() == nil)
    }

    @Test("currentDecision returns nil for an unknown plan")
    func currentDecisionReturnsNilForUnknownPlan() async throws {
        let store = try makeStore()

        #expect(try await store.currentDecision(for: FixPlanID()) == nil)
    }

    @Test("recordDecision saves the immediate successor revision")
    func recordDecisionSavesImmediateSuccessor() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let successor = FixPlanReviewer.rejectingAll(initial, at: Date(timeIntervalSince1970: 102))

        let result = try await store.recordDecision(successor)

        #expect(result == .saved(successor))
        #expect(try await store.currentDecision(for: plan.id) == successor)
    }

    @Test("recordDecision rejects a decision naming an item the plan never proposed")
    func recordDecisionRejectsUnknownItem() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let malformed = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: initial.revision.advanced(),
            decidedAt: Date(timeIntervalSince1970: 102),
            itemDecisions: [FixPlanItemDecision(itemID: UUID(), verdict: .accepted)]
        )

        await expectInvalidDecisionItems { _ = try await store.recordDecision(malformed) }
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("recordDecision rejects a decision missing plan items")
    func recordDecisionRejectsMissingItems() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let malformed = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: initial.revision.advanced(),
            decidedAt: Date(timeIntervalSince1970: 102),
            itemDecisions: []
        )

        await expectInvalidDecisionItems { _ = try await store.recordDecision(malformed) }
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("recordDecision rejects duplicate item decisions")
    func recordDecisionRejectsDuplicateItems() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let itemID = try #require(plan.items.first?.id)
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let malformed = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: initial.revision.advanced(),
            decidedAt: Date(timeIntervalSince1970: 102),
            itemDecisions: [
                FixPlanItemDecision(itemID: itemID, verdict: .accepted),
                FixPlanItemDecision(itemID: itemID, verdict: .rejected),
            ]
        )

        await expectInvalidDecisionItems { _ = try await store.recordDecision(malformed) }
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("savePlan rejects an initial decision misaligned with plan items")
    func savePlanRejectsMisalignedInitialDecision() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let malformed = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: .initial,
            decidedAt: Date(timeIntervalSince1970: 101),
            itemDecisions: [FixPlanItemDecision(itemID: UUID(), verdict: .accepted)]
        )

        await expectInvalidDecisionItems { try await store.savePlan(plan, initialDecision: malformed) }
        #expect(try await store.latestPlan() == nil)
    }

    @Test("recordDecision replaying the stored revision conflicts without mutation")
    func recordDecisionReplaySameRevisionConflicts() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let replay = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: .initial,
            decidedAt: Date(timeIntervalSince1970: 999),
            itemDecisions: plan.items.map { FixPlanItemDecision(itemID: $0.id, verdict: .rejected) }
        )

        let result = try await store.recordDecision(replay)

        #expect(result == .conflict(current: initial))
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("recordDecision skipping a revision conflicts without mutation")
    func recordDecisionSkippedRevisionConflicts() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let skipped = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: plan.revision,
            revision: ReviewDecisionRevision(3),
            decidedAt: Date(timeIntervalSince1970: 102),
            itemDecisions: initial.itemDecisions
        )

        let result = try await store.recordDecision(skipped)

        #expect(result == .conflict(current: initial))
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("recordDecision targeting a stale plan revision conflicts without mutation")
    func recordDecisionWrongPlanRevisionConflicts() async throws {
        let store = try makeStore()
        let plan = makePlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 101))
        try await store.savePlan(plan, initialDecision: initial)
        let stale = FixPlanReviewDecision(
            planID: plan.id,
            planRevision: FixPlanRevision(2),
            revision: initial.revision.advanced(),
            decidedAt: Date(timeIntervalSince1970: 102),
            itemDecisions: initial.itemDecisions
        )

        let result = try await store.recordDecision(stale)

        #expect(result == .conflict(current: initial))
        #expect(try await store.currentDecision(for: plan.id) == initial)
    }

    @Test("recordDecision throws missingPlan for an absent plan")
    func recordDecisionMissingPlanThrows() async throws {
        let store = try makeStore()
        let orphan = FixPlanReviewDecision(
            planID: FixPlanID(),
            planRevision: .initial,
            revision: .initial,
            decidedAt: Date(timeIntervalSince1970: 100),
            itemDecisions: []
        )

        do {
            _ = try await store.recordDecision(orphan)
            Issue.record("Expected recordDecision to throw FixPlanPersistenceError.missingPlan")
        } catch let error as FixPlanPersistenceError {
            guard case let .missingPlan(planID) = error else {
                Issue.record("Expected missingPlan, got \(error)")
                return
            }
            #expect(planID == orphan.planID.rawValue)
        }
    }

    @Test("garbage configuration blob throws corruptedField naming configuration")
    func garbageConfigurationBlobThrowsCorruptedField() async throws {
        let container = try makeContainer()
        let planID = UUID()
        try insertPersistedPlan(planID: planID, configSnapshotData: garbageData, into: container)
        let store = FixPlanDataStore(modelContainer: container)

        await expectCorruptedField(name: "configuration", planID: planID) {
            _ = try await store.latestPlan()
        }
    }

    @Test("garbage scope blob throws corruptedField naming scope")
    func garbageScopeBlobThrowsCorruptedField() async throws {
        let container = try makeContainer()
        let planID = UUID()
        try insertPersistedPlan(planID: planID, scopeSnapshotData: garbageData, into: container)
        let store = FixPlanDataStore(modelContainer: container)

        await expectCorruptedField(name: "scope", planID: planID) {
            _ = try await store.plan(id: FixPlanID(rawValue: planID), revision: .initial)
        }
    }

    @Test("garbage items blob throws corruptedField naming items")
    func garbageItemsBlobThrowsCorruptedField() async throws {
        let container = try makeContainer()
        let planID = UUID()
        try insertPersistedPlan(planID: planID, itemsData: garbageData, into: container)
        let store = FixPlanDataStore(modelContainer: container)

        await expectCorruptedField(name: "items", planID: planID) {
            _ = try await store.plan(id: FixPlanID(rawValue: planID), revision: .initial)
        }
    }

    @Test("garbage itemDecisions blob throws corruptedField naming itemDecisions")
    func garbageItemDecisionsBlobThrowsCorruptedField() async throws {
        let container = try makeContainer()
        let planID = UUID()
        try insertPersistedPlan(planID: planID, into: container)
        try insertPersistedDecision(planID: planID, itemDecisionsData: garbageData, into: container)
        let store = FixPlanDataStore(modelContainer: container)

        await expectCorruptedField(name: "itemDecisions", planID: planID) {
            _ = try await store.currentDecision(for: FixPlanID(rawValue: planID))
        }
    }

    @Test("latestPlan throws for a corrupted newest plan instead of skipping to an older one")
    func latestPlanThrowsForCorruptedNewestInsteadOfSkipping() async throws {
        let container = try makeContainer()
        let store = FixPlanDataStore(modelContainer: container)
        let valid = makePlan(createdAt: Date(timeIntervalSince1970: 100))
        try await store.savePlan(valid, initialDecision: FixPlanReviewer.initialDecision(
            for: valid,
            at: Date(timeIntervalSince1970: 101)
        ))
        let corruptedPlanID = UUID()
        try insertPersistedPlan(
            planID: corruptedPlanID,
            createdAt: Date(timeIntervalSince1970: 200),
            itemsData: garbageData,
            into: container
        )

        await expectCorruptedField(name: "items", planID: corruptedPlanID) {
            _ = try await store.latestPlan()
        }
    }

    // MARK: - Fixtures

    private var garbageData: Data {
        Data([0xDE, 0xAD, 0xBE, 0xEF])
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([PersistedFixPlan.self, PersistedFixPlanDecision.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeStore() throws -> FixPlanDataStore {
        try FixPlanDataStore(modelContainer: makeContainer())
    }

    private func makePlan(
        id: FixPlanID = FixPlanID(),
        revision: FixPlanRevision = .initial,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> FixPlan {
        FixPlan(
            id: id,
            revision: revision,
            sourceRunID: RunID(),
            createdAt: createdAt,
            configuration: makeConfiguration(),
            scope: makeScope(createdAt: createdAt),
            items: [makeItem()]
        )
    }

    private func makeConfiguration() -> FixPlanConfig {
        var appConfiguration = AppConfiguration()
        appConfiguration.cleaning.genreMappings = ["Electronic": "Electronica"]
        return FixPlanConfig(
            capturedAt: Date(timeIntervalSince1970: 90),
            appConfiguration: appConfiguration,
            options: UpdateOptions(
                updateGenre: true,
                updateYear: false,
                repairExistingGenreMismatches: true,
                cleanTrackNames: true,
                minConfidence: 80
            )
        )
    }

    private func makeScope(createdAt: Date = Date(timeIntervalSince1970: 100)) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: createdAt,
            reason: "manualCheck"
        )
    }

    private func makeItem() -> FixPlanItem {
        FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "read-1",
                appleScriptID: "script-1",
                artist: "Aphex Twin",
                album: "Syro",
                trackName: "minipops 67 (source field)"
            ),
            changeType: .genreUpdate,
            oldValue: "Electronic",
            newValue: "IDM",
            confidence: 95,
            source: "musicbrainz"
        )
    }

    private func insertPersistedPlan(
        planID: UUID,
        revision: Int = 1,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        configSnapshotData: Data? = nil,
        scopeSnapshotData: Data? = nil,
        itemsData: Data? = nil,
        into container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let configSnapshotData = try configSnapshotData ?? JSONEncoder().encode(makeConfiguration())
        let scopeSnapshotData = try scopeSnapshotData ?? JSONEncoder().encode(makeScope())
        let itemsData = try itemsData ?? JSONEncoder().encode([makeItem()])
        context.insert(PersistedFixPlan(
            planID: planID,
            revision: revision,
            sourceRunID: UUID(),
            createdAt: createdAt,
            configSnapshotData: configSnapshotData,
            scopeSnapshotData: scopeSnapshotData,
            itemsData: itemsData,
            itemCount: 1,
            scopeSource: ProcessingScopeSource.testArtists.rawValue,
            configFingerprint: "test-fingerprint"
        ))
        try context.save()
    }

    private func insertPersistedDecision(
        planID: UUID,
        itemDecisionsData: Data,
        into container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.insert(PersistedFixPlanDecision(
            planID: planID,
            planRevision: 1,
            decisionRevision: 1,
            decidedAt: Date(timeIntervalSince1970: 101),
            itemDecisionsData: itemDecisionsData
        ))
        try context.save()
    }

    private func expectInvalidDecisionItems(operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected FixPlanPersistenceError.invalidDecisionItems to be thrown")
        } catch let error as FixPlanPersistenceError {
            guard case .invalidDecisionItems = error else {
                Issue.record("Expected invalidDecisionItems, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected FixPlanPersistenceError, got \(error)")
        }
    }

    private func expectCorruptedField(
        name expectedName: String,
        planID expectedPlanID: UUID,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected FixPlanPersistenceError.corruptedField(\(expectedName)) to be thrown")
        } catch let error as FixPlanPersistenceError {
            guard case let .corruptedField(name, planID) = error else {
                Issue.record("Expected corruptedField, got \(error)")
                return
            }
            #expect(name == expectedName)
            #expect(planID == expectedPlanID)
        } catch {
            Issue.record("Expected FixPlanPersistenceError, got \(error)")
        }
    }
}
