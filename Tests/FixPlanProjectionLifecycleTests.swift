import Core
import Foundation
import Services
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
        dependencies.configureLibraryPersistenceForTesting(fixPlanStore: planStore)
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

    @Test("a changed preview publishes the fix plan produced by that run")
    func changedPreviewPublishesPlan() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        dependencies.configureLibraryPersistenceForTesting(
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

    @Test("relaunch does not resurrect a plan after a later observation changes the mirror")
    func relaunchHidesPlanAfterObservationChange() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let planStore = StoredFixPlanStore(plan: plan, decision: decision)
        let changedRun = makeRunRecord(
            runID: RunID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_200),
            intent: .observeLibrary,
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 1)
        )
        dependencies.configureLibraryPersistenceForTesting(
            runRecordStore: RunRecordStoreStub(reportPage: RunReportPage(
                records: [changedRun],
                skippedCorruptedCount: 0
            )),
            fixPlanStore: planStore
        )

        let projection = await dependencies.refreshFixPlanProjection()

        #expect(projection.status == .empty)
        #expect(try await planStore.latestPlan() == plan)
    }

    @Test("relaunch does not resurrect a plan after mirror maintenance")
    func relaunchHidesPlanAfterMirrorMaintenance() async throws {
        let dependencies = makeDependencies()
        let plan = try #require(try makePlan(dependencies: dependencies))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let planStore = StoredFixPlanStore(plan: plan, decision: decision)
        let maintenanceRun = makeRunRecord(
            runID: RunID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_200),
            intent: .previewFixes,
            syncSummary: ActivitySyncSummary(
                new: 0,
                modified: 0,
                identityChanged: 0,
                refreshed: 0,
                removed: 0,
                mirrorMaintenanceCount: 1
            )
        )
        dependencies.configureLibraryPersistenceForTesting(
            runRecordStore: RunRecordStoreStub(reportPage: RunReportPage(
                records: [maintenanceRun],
                skippedCorruptedCount: 0
            )),
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
        let sourceRun = makeRunRecord(
            runID: plan.sourceRunID,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 1)
        )
        dependencies.configureLibraryPersistenceForTesting(
            runRecordStore: RunRecordStoreStub(reportPage: RunReportPage(
                records: [sourceRun],
                skippedCorruptedCount: 0
            )),
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

    private func makeRunRecord(
        runID: RunID,
        startedAt: Date,
        intent: RunIntent = .previewFixes,
        syncSummary: ActivitySyncSummary
    ) -> RunRecord {
        let lifecycle = makeLifecycle(
            phase: .active(.created),
            intent: intent,
            runID: runID,
            startedAt: startedAt
        )
        return RunRecord(
            lifecycle: lifecycle,
            transitions: [RunLifecycleTransition(state: .completedNoOp, timestamp: startedAt)],
            syncSummary: syncSummary,
            failureMessage: nil,
            finishedAt: startedAt.addingTimeInterval(10)
        )
    }
}
