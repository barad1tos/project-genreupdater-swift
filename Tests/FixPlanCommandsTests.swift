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

    @Test("apply command submits the reviewed plan snapshot")
    func submitsPlanSnapshot() async {
        let harness = FixPlanCommandHarness(
            startingVerdict: .accepted,
            plan: makeCommandPlan(automationStrategy: .hybrid)
        )
        let commands = harness.makeCommands()
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_200)

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .accepted)
        #expect(result.message == "Applied 2 changes.")
        #expect(harness.writeCallCount() == 1)
        guard let input = harness.lastWriteInput() else {
            Issue.record("Expected a write input")
            return
        }
        #expect(input.target == harness.target.writeTarget)
        #expect(input.scope == harness.plan.scope)
        #expect(input.configuration.capturedAt == capturedAt)
        #expect(input.configuration.writeAuthority == .reviewedPlan)
        #expect(input.configuration.automation == .hybrid)
        #expect(input.configuration.scopeID == harness.plan.scope.id)
        #expect(input.configuration.settings == harness.plan.configuration)
        #expect(!input.configuration.hadRecoveryHold)
        #expect(input.workItems == harness.plan.items.map(RunWorkItem.init(item:)))
        #expect(await harness.store.recordCallCount() == 0)
    }

    @Test("apply submits only accepted review items")
    func filtersRejectedItems() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        let commands = harness.makeCommands()
        let rejectedID = harness.plan.items[0].id

        let review = await commands.handle(.togglePlanItem(rejectedID, target: harness.target))
        #expect(review.status == .accepted)

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .accepted)
        #expect(result.message == "Applied 1 change.")
        #expect(harness.writeCallCount() == 1)
        #expect(harness.lastWriteInput()?.workItems == [RunWorkItem(item: harness.plan.items[1])])
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

    @Test("apply command requires attention when write identity is missing")
    func missingWriteIDNeedsAttention() async {
        let harness = FixPlanCommandHarness(
            startingVerdict: .accepted,
            plan: makeCommandPlan(firstHasWriteID: false)
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.id == "fix-plan-write-identity")
        #expect(harness.writeCallCount() == 0)
    }

    @Test("stale plan takes priority over missing write identity")
    func stalePlanRefreshesFirst() async {
        let harness = FixPlanCommandHarness(
            startingVerdict: .accepted,
            plan: makeCommandPlan(firstHasWriteID: false)
        )
        harness.markProjectionStale()
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .rejectedStale)
        #expect(result.issue == nil)
        #expect(harness.writeCallCount() == 0)
    }

    @Test("recovery hold takes priority over missing write identity")
    func recoveryPrecedesSafety() async {
        let harness = FixPlanCommandHarness(
            startingVerdict: .accepted,
            plan: makeCommandPlan(firstHasWriteID: false)
        )
        harness.isRecoveryHeld = true
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .blockedByRecovery)
        #expect(result.issue?.id == "fix-plan-write-held")
        #expect(harness.writeCallCount() == 0)
    }

    @Test("apply command is blocked while recovery holds writes")
    func applyBlockedByRecoveryHold() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.isRecoveryHeld = true
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

    @Test("apply surfaces a recoverable write outcome")
    func applyRequiresRecovery() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.setRecoveryResult(reason: "Music.app write outcome is unknown")

        let result = await harness.makeCommands().handle(.applyFixPlan(target: harness.target))

        #expect(result.status == .blockedByRecovery)
        #expect(result.issue?.id == "fix-plan-write-recovery")
        #expect(result.issue?.category == .recoveryRequired)
        #expect(result.issue?.technicalDetail == "Music.app write outcome is unknown")
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

    @Test("remaining fixes submit the full accepted set as a linked continuation")
    func remainingFixesSubmitLinkedContinuation() async {
        let harness = FixPlanCommandHarness(
            startingVerdict: .accepted,
            plan: makeCommandPlan(automationStrategy: .scheduled)
        )
        let source = makeClosedSourceRecord(
            readIDs: ["read-00000000-0000-0000-0000-000000000201"],
            planTarget: harness.target.writeTarget
        )
        harness.sourceRecord = source
        harness.setWriteResult(.completedNoOp(FixPlanCommandHarness.finishedLifecycle()))
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyRemainingFixes(
            target: harness.target,
            sourceRunID: source.runID.rawValue
        ))

        #expect(result.status == .noOp)
        #expect(harness.submittedRequests.count == 1)
        #expect(harness.submittedRequests.first?.continuesRunID == source.runID)
        #expect(harness.submittedRequests.first?.trigger == .recovery)
        #expect(harness.submittedRequests.first?.writeInput?.configuration.automation == .scheduled)
        // The write runner validates input against exactly the full accepted
        // set; already-landed items verify as no-ops downstream.
        let items = harness.submittedRequests.first?.writeInput?.workItems ?? []
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.state == .prepared })
    }

    @Test("remaining fixes reject a source run that executed a different plan")
    func remainingFixesRejectForeignPlan() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.sourceRecord = makeClosedSourceRecord(
            readIDs: ["read-00000000-0000-0000-0000-000000000201"]
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyRemainingFixes(
            target: harness.target,
            sourceRunID: UUID()
        ))

        #expect(result.status == .rejectedStale)
        #expect(result.message == "The current review plan does not match the interrupted run.")
        #expect(harness.submittedRequests.isEmpty)
    }

    @Test("remaining fixes reject a vanished source run")
    func remainingFixesRejectMissingSource() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.sourceRecord = nil
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyRemainingFixes(
            target: harness.target,
            sourceRunID: UUID()
        ))

        #expect(result.status == .rejectedStale)
        #expect(harness.submittedRequests.isEmpty)
    }

    @Test("remaining fixes reject a stale decision triple without submitting")
    func remainingFixesRejectStaleTriple() async throws {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.sourceRecord = makeClosedSourceRecord(readIDs: ["read-00000000-0000-0000-0000-000000000201"])
        let commands = harness.makeCommands()
        let staleTarget = harness.target
        let current = try #require(await harness.store.currentDecision(for: staleTarget.planID))
        _ = try await harness.store.recordDecision(
            FixPlanReviewer.rejectingAll(current, at: Date(timeIntervalSince1970: 1_800_000_300))
        )

        let result = await commands.handle(.applyRemainingFixes(
            target: staleTarget,
            sourceRunID: UUID()
        ))

        #expect(result.status == .rejectedStale)
        #expect(harness.submittedRequests.isEmpty)
    }

    @Test("remaining fixes reject an open source run without submitting")
    func remainingFixesRejectOpenSource() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.sourceRecord = makeClosedSourceRecord(
            readIDs: ["read-00000000-0000-0000-0000-000000000201"],
            finished: false
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyRemainingFixes(
            target: harness.target,
            sourceRunID: UUID()
        ))

        #expect(result.status == .rejectedStale)
        #expect(result.message.contains("still open"))
        #expect(harness.submittedRequests.isEmpty)
    }

    @Test("remaining fixes stay blocked while a recovery hold is engaged")
    func remainingFixesBlockedByHold() async {
        let harness = FixPlanCommandHarness(startingVerdict: .accepted)
        harness.isRecoveryHeld = true
        harness.sourceRecord = makeClosedSourceRecord(readIDs: ["read-00000000-0000-0000-0000-000000000201"])
        let commands = harness.makeCommands()

        let result = await commands.handle(.applyRemainingFixes(
            target: harness.target,
            sourceRunID: UUID()
        ))

        #expect(result.status == .blockedByRecovery)
        #expect(harness.submittedRequests.isEmpty)
    }
}

private func makeFailedSourceItem(readID: String) -> RunWorkItem {
    RunWorkItem(
        id: UUID(),
        target: .track(FixPlanItemIdentity(
            readID: readID,
            appleScriptID: "script-1",
            artist: "Björk",
            album: "Homogenic",
            trackName: "Jóga"
        )),
        change: WorkChange(
            changeType: .genreUpdate,
            oldValue: "Alternative",
            newValue: "Art Pop",
            confidence: 92,
            source: "MusicBrainz"
        ),
        state: .outcome(.failed),
        detail: nil
    )
}

private func makeClosedSourceRecord(
    readIDs: [String],
    finished: Bool = true,
    planTarget: FixPlanWriteTarget? = nil
) -> RunRecord {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: 1,
        createdAt: startedAt,
        reason: "continuation-command-test"
    )
    let items = readIDs.map(makeFailedSourceItem)
    let input = FixPlanWriteInput(
        target: planTarget
            ?? FixPlanWriteTarget(planID: FixPlanID(), planRevision: .initial, decisionRevision: .initial),
        scope: scope,
        admission: workflowProcessingAdmission(scope: scope),
        configuration: RunConfig(
            capturedAt: startedAt,
            writeAuthority: .reviewedPlan,
            automation: .manualOnly,
            scopeID: scope.id,
            settings: FixPlanConfig.capture(
                configuration: AppConfiguration(),
                options: UpdateOptions(),
                capturedAt: startedAt
            ),
            hadRecoveryHold: false
        ),
        workItems: items
    )
    let lifecycle = RunLifecycleSnapshot(
        request: .manualWrite(input: input),
        scope: scope,
        startedAt: startedAt,
        phase: .active(.writing)
    )
    return RunRecord(
        lifecycle: lifecycle,
        transitions: [
            RunLifecycleTransition(state: .writing, timestamp: startedAt),
            RunLifecycleTransition(state: .cancelled, timestamp: startedAt.addingTimeInterval(5)),
        ],
        syncSummary: nil,
        failureMessage: nil,
        finishedAt: finished ? startedAt.addingTimeInterval(5) : nil
    )
}
