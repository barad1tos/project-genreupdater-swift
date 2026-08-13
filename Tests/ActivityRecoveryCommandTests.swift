import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Activity recovery commands")
@MainActor
struct ActivityRecoveryCommandTests {
    @Test("continue writes maps a completed release to accepted")
    func completedReleaseAccepted() async {
        let snapshot = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            intent: .writeFixes
        )
        let harness = ActivityFixtures.Harness(releaseOutcome: .released(.completed(snapshot)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .accepted)
        #expect(harness.releaseCallCount == 1)
    }

    @Test("continue writes reports a re-engaged hold as blocked")
    func reengagedHoldBlocks() async {
        let harness = ActivityFixtures.Harness(releaseOutcome: .released(.recoveryRequired))
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .blockedByRecovery)
        #expect(result.issue?.id == "queued-write-reheld")
    }

    @Test("continue writes maps a blocked release without consuming intent")
    func blockedReleasePreservesIntent() async {
        let harness = ActivityFixtures.Harness(releaseOutcome: .blocked)
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .blockedByRecovery)
        #expect(result.issue?.id == "queued-write-blocked")
    }

    @Test("continue writes maps an empty slot to stale")
    func emptySlotIsStale() async {
        let harness = ActivityFixtures.Harness(releaseOutcome: .empty)
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .rejectedStale)
    }

    @Test("continue writes maps stale consent to a re-review prompt")
    func staleConsentRequestsReview() async {
        let harness = ActivityFixtures.Harness(releaseOutcome: .stale)
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .rejectedStale)
        #expect(result.message.contains("Review the plan"))
    }

    @Test("continue writes surfaces a missing consent source as internal failure")
    func missingSourceRequiresAttention() async {
        let harness = ActivityFixtures.Harness(releaseOutcome: .unverifiable(.sourceMissing))
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.category == .internalFailure)
    }

    @Test("continue writes reports an unverifiable plan without destructive advice")
    func missingDecisionKeepsIntent() async {
        let harness = ActivityFixtures.Harness(releaseOutcome: .unverifiable(.noCurrentDecision))
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .requiresAttention)
        // The slot is retained upstream; the message must not assert absence
        // as fact nor advise destroying the retained intent.
        #expect(result.message.contains("still held"))
        #expect(!result.message.contains("Discard the queued write"))
    }

    @Test("grouped dismissal reports the count and forwards the selection")
    func groupedDismissalForwardsSelection() async {
        let harness = ActivityFixtures.Harness()
        let commands = harness.makeCommands()
        let runID = UUID()
        let itemIDs = [UUID(), UUID()]

        let result = await commands.handle(.dismissRecoveryItems(
            runID: runID,
            itemIDs: itemIDs,
            reason: "duplicates"
        ))

        #expect(result.status == .accepted)
        #expect(result.message.contains("2 items"))
        #expect(harness.dismissals.count == 1)
        #expect(harness.dismissals.first?.runID == runID)
        #expect(harness.dismissals.first?.itemIDs == itemIDs)
        #expect(harness.dismissals.first?.isIndividual == false)
    }

    @Test("individual dismissal forwards the explicit-decision flag")
    func individualDismissalForwardsFlag() async {
        let harness = ActivityFixtures.Harness()
        let commands = harness.makeCommands()

        let result = await commands.handle(.dismissRecoveryItem(
            runID: UUID(),
            itemID: UUID(),
            reason: "checked manually"
        ))

        #expect(result.status == .accepted)
        #expect(harness.dismissals.first?.isIndividual == true)
    }

    @Test("a domain gate rejection maps to an invalid dismissal")
    func domainRejectionIsInvalid() async {
        let harness = ActivityFixtures.Harness()
        harness.dismissalError = WorkCheckpointError.invalid(
            .afterVerification,
            writeAdjacent: true,
            reason: "grouped dismissal cannot cover 1 write-uncertain item(s)"
        )
        let commands = harness.makeCommands()

        let result = await commands.handle(.dismissRecoveryItems(
            runID: UUID(),
            itemIDs: [UUID()],
            reason: "cleanup"
        ))

        #expect(result.status == .rejectedInvalid)
        #expect(result.issue?.category == .safetyBlocked)
    }

    @Test("an infrastructure failure maps dismissal to attention")
    func storeFailureNeedsAttention() async {
        let harness = ActivityFixtures.Harness()
        harness.dismissalError = RecoveryCommandError(errorDescription: "store offline")
        let commands = harness.makeCommands()

        let result = await commands.handle(.dismissRecoveryItem(
            runID: UUID(),
            itemID: UUID(),
            reason: "cleanup"
        ))

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.category == .internalFailure)
    }

    @Test("continue writes maps a failed released run to attention")
    func failedReleaseNeedsAttention() async {
        let snapshot = ActivityFixtures.lifecycle(
            phase: .finished(.failed(message: "Write failed"), finishedAt: ActivityFixtures.finishDate),
            intent: .writeFixes
        )
        let harness = ActivityFixtures.Harness(releaseOutcome: .released(.failed(snapshot)))
        let commands = harness.makeCommands()

        let result = await commands.handle(.continueWrites())

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.id == "queued-write-failed")
    }
}

private struct RecoveryCommandError: LocalizedError {
    let errorDescription: String?
}
