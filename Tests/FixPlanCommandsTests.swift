import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("FixPlanCommands")
@MainActor
struct FixPlanCommandsTests {
    @Test("accept command updates persisted decision and refreshed projections")
    func acceptCommandUpdatesDecision() async {
        let harness = FixPlanCommandHarness(startingVerdict: .rejected)
        let commands = harness.makeCommands()

        let result = await commands.handle(.acceptFixPlan(target: harness.target))

        #expect(result.status == .accepted)
        #expect(result.message == "Review updated.")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 2)
        #expect(result.refreshedFixPlanProjection?.decisionRevision == ReviewDecisionRevision(3))
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(11))
        #expect(await harness.store.recordCallCount() == 1)
        #expect(await harness.store.verdicts() == [.accepted, .accepted])
    }

    @Test("known item toggle updates one decision and refreshes projections")
    func knownItemToggleUpdatesDecision() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()
        let itemID = harness.plan.items[0].id

        let result = await commands.handle(.togglePlanItem(itemID, target: harness.target))

        #expect(result.status == .accepted)
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 1)
        #expect(result.refreshedFixPlanProjection?.rejectedCount == 1)
        #expect(result.refreshedFixPlanProjection?.decisionRevision == ReviewDecisionRevision(2))
        #expect(await harness.store.recordCallCount() == 1)
        #expect(await harness.store.verdicts() == [.rejected, .accepted])
    }

    @Test("accepting an already accepted plan is a no-op")
    func acceptAlreadyAcceptedPlanIsNoOp() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()

        let result = await commands.handle(.acceptFixPlan(target: harness.target))

        #expect(result.status == .noOp)
        #expect(result.message == "Review already up to date.")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 2)
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(11))
        #expect(await harness.store.recordCallCount() == 0)
        #expect(await harness.store.verdicts() == [.accepted, .accepted])
    }

    @Test("reject command updates persisted decision and refreshed projections")
    func rejectCommandUpdatesDecision() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()

        let result = await commands.handle(.rejectFixPlan(target: harness.target))

        #expect(result.status == .accepted)
        #expect(result.message == "Review updated.")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 0)
        #expect(result.refreshedFixPlanProjection?.rejectedCount == 2)
        #expect(result.refreshedFixPlanProjection?.decisionRevision == ReviewDecisionRevision(2))
        #expect(await harness.store.recordCallCount() == 1)
        #expect(await harness.store.verdicts() == [.rejected, .rejected])
    }

    @Test("rejecting an already rejected plan is a no-op")
    func rejectAlreadyRejectedPlanIsNoOp() async {
        let harness = FixPlanCommandHarness(startingVerdict: .rejected)
        let commands = harness.makeCommands()

        let result = await commands.handle(.rejectFixPlan(target: harness.target))

        #expect(result.status == .noOp)
        #expect(result.message == "Review already up to date.")
        #expect(result.refreshedFixPlanProjection?.rejectedCount == 2)
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(11))
        #expect(await harness.store.recordCallCount() == 0)
        #expect(await harness.store.verdicts() == [.rejected, .rejected])
    }

    @Test("record conflict rejects stale without mutating decision")
    func recordConflictRejectsStale() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        await harness.store.conflictOnNextRecord()
        let commands = harness.makeCommands()

        let result = await commands.handle(.rejectFixPlan(target: harness.target))

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Review changed. Refreshing current plan.")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 2)
        #expect(await harness.store.recordCallCount() == 1)
        #expect(await harness.store.verdicts() == [.accepted, .accepted])
    }

    @Test("missing store returns temporary unavailable")
    func missingStoreReturnsUnavailable() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands(fixPlanStore: nil)

        let result = await commands.handle(.acceptFixPlan(target: harness.target))

        #expect(result.status == .temporaryUnavailable)
        #expect(result.issue?.id == "fix-plan-store-unavailable")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 2)
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(11))
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("missing current decision rejects invalid target")
    func missingCurrentDecisionRejectsInvalidTarget() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        await harness.store.removeDecision()
        let commands = harness.makeCommands()

        let result = await commands.handle(.acceptFixPlan(target: harness.target))

        #expect(result.status == .rejectedInvalid)
        #expect(result.issue?.id == "fix-plan-command-invalid")
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("missing plan during record is reported as stale")
    func missingPlanDuringRecordRejectsStale() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        await harness.store.missingPlanOnNextRecord()
        let commands = harness.makeCommands()

        let result = await commands.handle(.rejectFixPlan(target: harness.target))

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Review changed. Refreshing current plan.")
        #expect(await harness.store.recordCallCount() == 1)
        #expect(await harness.store.verdicts() == [.accepted, .accepted])
    }

    @Test("unsupported command kind rejects invalid")
    func unsupportedCommandKindRejectsInvalid() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(result.status == .rejectedInvalid)
        #expect(result.issue?.id == "fix-plan-command-invalid")
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("store write failure requires attention")
    func storeWriteFailureRequiresAttention() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        await harness.store.throwOnNextRecord()
        let commands = harness.makeCommands()

        let result = await commands.handle(.rejectFixPlan(target: harness.target))

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.id == "fix-plan-review-failed")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 2)
        #expect(await harness.store.recordCallCount() == 1)
        #expect(await harness.store.verdicts() == [.accepted, .accepted])
    }

    @Test("fix plan route includes issue detail")
    func routeShowsDetail() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        await harness.store.throwOnNextRecord()
        let commands = harness.makeCommands()
        var handledResult: UserCommandResult?
        var showsActivityNotice: Bool?
        var shownNotice: FixPlanCommands.Notice?

        let result = await commands.handle(.rejectFixPlan(target: harness.target))
        FixPlanCommands.showResult(
            result,
            handleResult: { result, showsNotice in
                handledResult = result
                showsActivityNotice = showsNotice
            },
            showNotice: { notice in
                shownNotice = notice
            }
        )

        #expect(handledResult?.status == .requiresAttention)
        #expect(showsActivityNotice == false)
        #expect(shownNotice == FixPlanCommands.Notice(
            message: "Review update failed. Test store write failed",
            status: .requiresAttention
        ))
    }

    @Test("fix plan notice omits repeated issue summary")
    func noticeDeduplicatesIssue() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()

        let result = await commands.handle(.runManually())

        #expect(
            FixPlanCommands.noticeText(for: result) ==
                "Review action is unavailable. Unsupported command kind: runManually"
        )
    }

    @Test("fix plan notice keeps plain success text")
    func noticeKeepsSuccess() async {
        let harness = FixPlanCommandHarness(startingVerdict: .rejected)
        let commands = harness.makeCommands()

        let result = await commands.handle(.acceptFixPlan(target: harness.target))

        #expect(FixPlanCommands.noticeText(for: result) == "Review updated.")
    }

    @Test("apply command submits the exact reviewed fix plan target")
    func applyCommandSubmitsTarget() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .accepted)
        #expect(result.message == "Applied 2 changes.")
        #expect(harness.writeCallCount() == 1)
        #expect(harness.lastWriteTarget() == harness.target.applyTarget)
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("apply command is a no-op when no items are accepted")
    func applyWithoutAcceptedIsNoOp() async {
        let harness = FixPlanCommandHarness(startingVerdict: .rejected)
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .noOp)
        #expect(result.message == "No accepted changes to apply.")
        #expect(harness.writeCallCount() == 0)
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("apply command rejects stale projections with accepted items")
    func applyRejectsStale() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.markProjectionStale()
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Fix plan changed. Refreshing current plan.")
        #expect(result.refreshedFixPlanProjection?.status == .stale)
        #expect(harness.writeCallCount() == 0)
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("apply command is blocked while recovery holds writes")
    func applyBlockedByRecoveryHold() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.recoveryHold = true
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .blockedByRecovery)
        #expect(result.issue?.id == "fix-plan-write-held")
        #expect(harness.writeCallCount() == 0)
    }

    @Test("apply command surfaces write submission failure")
    func applyFailureNeedsAttention() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.failNextWrite(StoreWriteError())
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .requiresAttention)
        #expect(result.message == "Write run failed.")
        #expect(result.issue?.id == "fix-plan-write-failed")
        #expect(result.issue?.technicalDetail == "Test store write failed")
        #expect(harness.writeCallCount() == 1)
    }

    @Test("stale command rejects without recording a newer decision")
    func staleCommandRejectsWithoutRecording() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let staleTarget = harness.target
        await harness.store.replaceDecision(FixPlanReviewer.rejectingAll(
            harness.store.currentDecision(),
            at: Date(timeIntervalSince1970: 1_800_000_300)
        ))
        let commands = harness.makeCommands()

        let result = await commands.handle(.rejectFixPlan(target: staleTarget))

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Review changed. Refreshing current plan.")
        #expect(result.refreshedFixPlanProjection?.rejectedCount == 2)
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("unknown item toggle rejects without mutating the decision")
    func unknownItemToggleRejectsWithoutMutating() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()

        let result = await commands.handle(.togglePlanItem(UUID(), target: harness.target))

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Review item is no longer available.")
        #expect(result.refreshedFixPlanProjection?.acceptedCount == 2)
        #expect(await harness.store.recordCallCount() == 0)
        #expect(await harness.store.verdicts() == [.accepted, .accepted])
    }
}

@MainActor
private final class FixPlanCommandHarness {
    let plan: FixPlan
    let store: MemoryFixPlanStore
    private var fixPlanProjection: FixPlanProjection
    private var activityProjection = ActivityProjection.empty(revision: ProjectionRevision(10))
    private var shouldRefreshProjection = true
    private var writeResult: RunSubmissionResult?
    private var writeError: (any Error)?
    private var writeTargets: [FixPlanApplyTarget] = []
    var recoveryHold = false

    init(startingVerdict: FixPlanItemVerdict) {
        plan = makeCommandPlan()
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let decision = startingVerdict == .accepted
            ? initial
            : FixPlanReviewer.rejectingAll(initial, at: Date(timeIntervalSince1970: 1_800_000_102))
        store = MemoryFixPlanStore(plan: plan, decision: decision)
        fixPlanProjection = Self.makeProjection(plan: plan, decision: decision).withRevision(ProjectionRevision(4))
    }

    var target: FixPlanCommandTarget {
        FixPlanCommandTarget(
            planID: plan.id,
            planRevision: plan.revision,
            decisionRevision: fixPlanProjection.decisionRevision ?? .initial,
            projectionRevision: fixPlanProjection.revision
        )
    }

    func makeCommands() -> FixPlanCommands {
        makeCommands(fixPlanStore: store)
    }

    func makeCommands(fixPlanStore: (any FixPlanStore)?) -> FixPlanCommands {
        FixPlanCommands(
            fixPlanStore: fixPlanStore,
            submitFixPlanWrite: { [self] target in
                try await submitWrite(target: target)
            },
            hasRecoveryHold: { [self] in
                recoveryHold
            },
            refreshFixPlanProjection: { [self] in
                await refreshFixPlanProjection()
            },
            refreshActivityProjection: { [self] in
                refreshActivityProjection()
            },
            now: { Date(timeIntervalSince1970: 1_800_000_200) }
        )
    }

    func setWriteResult(_ result: RunSubmissionResult) {
        writeResult = result
    }

    func markProjectionStale() {
        fixPlanProjection = FixPlanProjection(
            revision: fixPlanProjection.revision,
            status: .stale,
            lineage: fixPlanProjection.lineage,
            summary: FixPlanProjection.Summary(
                itemCount: fixPlanProjection.itemCount,
                acceptedCount: fixPlanProjection.acceptedCount,
                rejectedCount: fixPlanProjection.rejectedCount,
                genreCount: fixPlanProjection.genreCount,
                yearCount: fixPlanProjection.yearCount,
                averageConfidence: fixPlanProjection.averageConfidence,
                canApply: false
            ),
            stalenessReasons: [.scopeChanged],
            items: fixPlanProjection.items,
            operationalIssues: fixPlanProjection.operationalIssues
        )
        shouldRefreshProjection = false
    }

    func failNextWrite(_ error: any Error) {
        writeError = error
    }

    func writeCallCount() -> Int {
        writeTargets.count
    }

    func lastWriteTarget() -> FixPlanApplyTarget? {
        writeTargets.last
    }

    private func submitWrite(target: FixPlanApplyTarget) async throws -> RunSubmissionResult {
        writeTargets.append(target)
        if let writeError {
            self.writeError = nil
            throw writeError
        }
        return writeResult ?? .completed(Self.writeLifecycle(changeCount: 2))
    }

    private func refreshFixPlanProjection() async -> FixPlanProjection {
        guard shouldRefreshProjection else {
            return fixPlanProjection
        }
        guard let decision = try? await store.currentDecision(for: plan.id) else {
            return fixPlanProjection
        }
        let candidate = Self.makeProjection(plan: plan, decision: decision)
        if candidate.withRevision(fixPlanProjection.revision) == fixPlanProjection {
            return fixPlanProjection
        }
        fixPlanProjection = candidate.withRevision(fixPlanProjection.revision.advanced())
        return fixPlanProjection
    }

    private func refreshActivityProjection() -> ActivityProjection {
        activityProjection = activityProjection.withRevision(activityProjection.revision.advanced())
        return activityProjection
    }

    private static func makeProjection(
        plan: FixPlan,
        decision: FixPlanReviewDecision
    ) -> FixPlanProjection {
        FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )
    }

    private static func writeLifecycle(changeCount: Int) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(rawValue: commandUUID("00000000-0000-0000-0000-000000000301")),
            requestID: RunRequestID(rawValue: commandUUID("00000000-0000-0000-0000-000000000302")),
            trigger: .manualCheck,
            intent: .writeFixes,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Björk"],
                knownTrackCount: 12,
                createdAt: Date(timeIntervalSince1970: 1_800_000_250),
                reason: "fixPlanWrite"
            ),
            startedAt: Date(timeIntervalSince1970: 1_800_000_250),
            phase: .finished(.completed(writeSyncResult(changeCount: changeCount)), finishedAt: Date(
                timeIntervalSince1970: 1_800_000_260
            ))
        )
    }

    private static func writeSyncResult(changeCount: Int) -> SyncResult {
        SyncResult(modifiedTracks: (0 ..< changeCount).map { index in
            Track(id: "written-\(index)", name: "Jóga", artist: "Björk", album: "Homogenic")
        })
    }
}

private actor MemoryFixPlanStore: FixPlanStore {
    private enum RecordBehavior {
        case save
        case conflict
        case missingPlan
        case throwError
    }

    private let plan: FixPlan
    private var decision: FixPlanReviewDecision?
    private var recordBehavior = RecordBehavior.save
    private var recordCalls = 0

    init(plan: FixPlan, decision: FixPlanReviewDecision) {
        self.plan = plan
        self.decision = decision
    }

    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {}

    func plan(id: FixPlanID, revision: FixPlanRevision) async throws -> FixPlan? {
        guard plan.id == id, plan.revision == revision else { return nil }
        return plan
    }

    func latestPlan() async throws -> FixPlan? {
        plan
    }

    func currentDecision(for planID: FixPlanID) async throws -> FixPlanReviewDecision? {
        guard plan.id == planID else { return nil }
        return decision
    }

    func recordDecision(_ decision: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        recordCalls += 1
        switch recordBehavior {
        case .save:
            break
        case .conflict:
            recordBehavior = .save
            return .conflict(current: currentDecision())
        case .missingPlan:
            recordBehavior = .save
            throw FixPlanPersistenceError.missingPlan(planID: plan.id.rawValue)
        case .throwError:
            recordBehavior = .save
            throw StoreWriteError()
        }

        let current = currentDecision()
        guard decision.planID == plan.id,
              decision.planRevision == current.planRevision,
              decision.revision == current.revision.advanced()
        else {
            return .conflict(current: current)
        }
        self.decision = decision
        return .saved(decision)
    }

    func currentDecision() -> FixPlanReviewDecision {
        guard let decision else {
            preconditionFailure("missing decision")
        }
        return decision
    }

    func replaceDecision(_ decision: FixPlanReviewDecision) {
        self.decision = decision
    }

    func removeDecision() {
        decision = nil
    }

    func conflictOnNextRecord() {
        recordBehavior = .conflict
    }

    func missingPlanOnNextRecord() {
        recordBehavior = .missingPlan
    }

    func throwOnNextRecord() {
        recordBehavior = .throwError
    }

    func recordCallCount() -> Int {
        recordCalls
    }

    func verdicts() -> [FixPlanItemVerdict] {
        currentDecision().itemDecisions.map(\.verdict)
    }
}

private struct StoreWriteError: LocalizedError {
    var errorDescription: String? {
        "Test store write failed"
    }
}

private func makeCommandPlan() -> FixPlan {
    FixPlan(
        id: FixPlanID(rawValue: commandUUID("00000000-0000-0000-0000-000000000101")),
        revision: .initial,
        sourceRunID: RunID(rawValue: commandUUID("00000000-0000-0000-0000-000000000102")),
        createdAt: Date(timeIntervalSince1970: 1_800_000_100),
        configuration: FixPlanConfigurationSnapshot.capture(
            options: UpdateOptions(
                updateGenre: true,
                updateYear: true,
                repairExistingGenreMismatches: false,
                forceYearLookup: false,
                cleanTrackNames: false,
                cleanAlbumNames: false,
                minConfidence: 80,
                autoAccept: false
            ),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_090)
        ),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Björk"],
            knownTrackCount: 12,
            createdAt: Date(timeIntervalSince1970: 1_800_000_091),
            reason: "fixPlanCommandTest"
        ),
        items: [
            makeCommandItem(id: "00000000-0000-0000-0000-000000000201", type: .genreUpdate),
            makeCommandItem(id: "00000000-0000-0000-0000-000000000202", type: .yearUpdate)
        ]
    )
}

private func makeCommandItem(id: String, type: ChangeType) -> FixPlanItem {
    let itemID = commandUUID(id)
    return FixPlanItem(
        id: itemID,
        identity: FixPlanItemIdentity(
            readID: "read-\(id)",
            appleScriptID: "script-\(id)",
            artist: "Björk",
            album: "Homogenic",
            trackName: type == .genreUpdate ? "Jóga" : "Bachelorette"
        ),
        changeType: type,
        oldValue: type == .genreUpdate ? "Alternative" : "1998",
        newValue: type == .genreUpdate ? "Art Pop" : "1997",
        confidence: 92,
        source: "MusicBrainz"
    )
}

private func commandUUID(_ rawValue: String) -> UUID {
    guard let uuid = UUID(uuidString: rawValue) else {
        preconditionFailure("Invalid fix-plan command fixture UUID: \(rawValue)")
    }
    return uuid
}
