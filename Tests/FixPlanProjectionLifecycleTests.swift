import Core
import Foundation
import Services
import SwiftData
import Testing
@testable import Genre_Updater

@Suite("Fix plan projection lifecycle")
@MainActor
struct FixPlanProjectionLifecycleTests {
    @Test("a maintenance-only observation does not resurrect an older fix plan")
    func maintenanceOnlyObservationHidesOlderPlan() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let planStore = StoredFixPlanStore(plan: plan, decision: decision)
        try await dependencies.configureLibraryPersistenceForTesting(
            trackStore: makeTrackStore(),
            fixPlanStore: planStore
        )
        _ = await dependencies.refreshFixPlanProjection()

        await dependencies.publishLifecycleBoundary(makeLifecycle(
            phase: .finished(
                .completedNoOp(SyncResult(mirrorMaintenanceCount: 1)),
                finishedAt: Date(timeIntervalSince1970: 200)
            ),
            intent: .observeLibrary
        ))

        #expect(await dependencies.projectionStore.fixPlanProjection().status == .empty)
        #expect(try await planStore.latestPlan() == plan)
    }

    @Test("a no-op terminal keeps a historically superseded plan hidden")
    func noOpKeepsPlanHidden() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let planStore = StoredFixPlanStore(plan: plan, decision: decision)
        try await dependencies.configureLibraryPersistenceForTesting(
            trackStore: makeTrackStore(contentChanges: 1, noOpCommits: 1),
            fixPlanStore: planStore
        )
        _ = await dependencies.refreshFixPlanProjection()

        await dependencies.publishLifecycleBoundary(makeLifecycle(
            phase: .finished(
                .completedNoOp(SyncResult()),
                finishedAt: Date(timeIntervalSince1970: 1_800_000_300)
            ),
            intent: .previewFixes,
            startedAt: Date(timeIntervalSince1970: 1_800_000_290)
        ))

        #expect(await dependencies.projectionStore.fixPlanProjection().status == .empty)
        #expect(try await planStore.latestPlan() == plan)
    }

    @Test("a changed preview publishes the fix plan produced by that run")
    func changedPreviewPublishesPlan() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        try await dependencies.configureLibraryPersistenceForTesting(
            trackStore: makeTrackStore(),
            fixPlanStore: StoredFixPlanStore(plan: plan, decision: decision)
        )

        await dependencies.publishLifecycleBoundary(makeLifecycle(
            phase: .finished(
                .completed(SyncResult(removedTrackIDs: ["legacy-alias"])),
                finishedAt: Date(timeIntervalSince1970: 200)
            ),
            intent: .previewFixes,
            runID: plan.sourceRunID
        ))

        let projection = await dependencies.projectionStore.fixPlanProjection()
        #expect(projection.status == .ready)
        #expect(projection.sourceRunID == plan.sourceRunID)
    }

    @Test(
        "relaunch does not resurrect a plan after mirror content changes",
        arguments: MirrorContentChange.allCases
    )
    func relaunchHidesSupersededPlan(_ contentChange: MirrorContentChange) async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let planStore = StoredFixPlanStore(plan: plan, decision: decision)
        try await dependencies.configureLibraryPersistenceForTesting(
            trackStore: makeTrackStore(contentChange: contentChange),
            fixPlanStore: planStore
        )

        let projection = await dependencies.refreshFixPlanProjection()

        #expect(projection.status == .empty)
        #expect(try await planStore.latestPlan() == plan)
    }

    @Test("relaunch publishes the newest preview run's plan")
    func relaunchPublishesCurrentPlan() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        try await dependencies.configureLibraryPersistenceForTesting(
            trackStore: makeTrackStore(),
            fixPlanStore: StoredFixPlanStore(plan: plan, decision: decision)
        )

        let projection = await dependencies.refreshFixPlanProjection()

        #expect(projection.status == .ready)
        #expect(projection.sourceRunID == plan.sourceRunID)
    }

    private func makeDependencies() -> AppDependencies {
        AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Configuration persistence is outside these projection lifecycle tests.
            }
        )
    }

    private func makeTrackStore(
        contentChanges: Int = 0,
        noOpCommits: Int = 0,
        contentChange: MirrorContentChange? = nil
    ) async throws -> TrackDataStore {
        let store: TrackDataStore
        if contentChange == .maintenance {
            let container = try ModelContainerFactory.createInMemory()
            let context = ModelContext(container)
            context.insert(PersistedTrack(
                trackID: "legacy",
                name: "Track",
                artist: "Artist",
                album: "Album"
            ))
            try context.save()
            store = TrackDataStore(modelContainer: container)
        } else {
            store = try TrackDataStore.createInMemory()
        }
        try await store.initialize()
        var revision = MirrorRevision.initial
        for _ in 0 ..< contentChanges {
            let result = try await store.commitMirror(MirrorCommit(
                baseRevision: revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve,
                effects: [.refreshProjections]
            ))
            revision = result.revision
        }
        for _ in 0 ..< noOpCommits {
            let result = try await store.commitMirror(MirrorCommit(
                baseRevision: revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve
            ))
            revision = result.revision
        }
        if let contentChange {
            revision = try await contentChange.apply(to: store, baseRevision: revision)
        }
        return store
    }

    private func makePlan(dependencies: AppDependencies) throws -> FixPlan? {
        try makeStoredFixPlan(configuration: dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 1_800_000_100),
            hasDiscogsAccess: true
        ))
    }

    private func makeLifecycle(
        phase: RunPhase,
        intent: RunIntent,
        runID: RunID = RunID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: runID,
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: intent,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: "fix-plan-lifecycle-test"
            ),
            startedAt: startedAt,
            phase: phase
        )
    }
}

enum MirrorContentChange: CaseIterable, CustomTestStringConvertible, Sendable {
    case observation
    case maintenance

    var testDescription: String {
        switch self {
        case .observation: "observation"
        case .maintenance: "maintenance"
        }
    }

    func apply(to store: TrackDataStore, baseRevision: MirrorRevision) async throws -> MirrorRevision {
        switch self {
        case .observation:
            try await store.commitMirror(MirrorCommit(
                baseRevision: baseRevision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [Self.track(id: "observed")],
                certificates: .invalidate(.incompleteObservation),
                effects: [.refreshProjections]
            )).revision
        case .maintenance:
            try await store.commitMirror(MirrorCommit(
                baseRevision: baseRevision,
                inventoryChange: .preserve,
                repairs: [TrackMirrorRepair(
                    sourceIDs: ["legacy"],
                    target: Self.track(id: "canonical")
                )],
                upserts: [],
                certificates: .invalidate(.incompleteObservation),
                effects: [.refreshProjections]
            )).revision
        }
    }

    private static func track(id: String) -> Core.Track {
        Core.Track(
            id: id,
            name: "Track",
            artist: "Artist",
            album: "Album",
            appleScriptID: id
        )
    }
}
