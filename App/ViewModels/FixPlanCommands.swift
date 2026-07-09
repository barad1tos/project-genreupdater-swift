import Foundation
import Services

@MainActor
struct FixPlanCommands {
    struct Notice: Equatable {
        let message: String
        let status: CommandResultStatus
    }

    static func showResult(
        _ result: UserCommandResult,
        handleResult: (UserCommandResult, Bool) -> Void,
        showNotice: (Notice) -> Void
    ) {
        handleResult(result, false)
        showNotice(Notice(message: noticeText(for: result), status: result.status))
    }

    static func noticeText(for result: UserCommandResult) -> String {
        guard let detail = result.issue?.technicalDetail, !detail.isEmpty else { return result.message }
        return "\(result.message) \(detail)"
    }

    private enum DecisionUpdate {
        case changed(FixPlanReviewDecision)
        case noOp
        case unavailableItem
    }

    private enum DecisionResolution {
        case update(FixPlanReviewDecision)
        case result(UserCommandResult)
    }

    let fixPlanStore: (any FixPlanStore)?
    let submitFixPlanWrite: (FixPlanWriteTarget) async throws -> RunSubmissionResult
    let hasRecoveryHold: () async -> Bool
    let refreshFixPlanProjection: () async -> FixPlanProjection
    let refreshActivityProjection: () async -> ActivityProjection
    let now: () -> Date

    func handle(_ command: UserIntentCommand) async -> UserCommandResult {
        guard isFixPlanCommand(command.kind) else {
            return await invalidCommand(command)
        }
        guard let target = command.fixPlanTarget else {
            let projection = await refreshFixPlanProjection()
            return await invalidTargetResult(
                detail: "Missing fix plan command target",
                projection: projection
            )
        }
        guard let fixPlanStore else {
            return await unavailableStoreResult(target: target)
        }

        let projection = await refreshFixPlanProjection()
        guard targetMatchesProjection(target, in: projection) else {
            return await staleResult(message: "Review changed. Refreshing current plan.", projection: projection)
        }
        guard projection.status == .ready || command.kind == .applyFixPlan else {
            return await staleResult(message: "Review changed. Refreshing current plan.", projection: projection)
        }

        do {
            guard let decision = try await fixPlanStore.currentDecision(for: target.planID) else {
                return await invalidTargetResult(detail: "Missing review decision for fix plan", projection: projection)
            }
            guard decision.planRevision == target.planRevision,
                  decision.revision == target.decisionRevision
            else {
                return await staleResult(message: "Review changed. Refreshing current plan.", projection: projection)
            }
            return try await handleValidatedCommand(
                command,
                target: target,
                decision: decision,
                projection: projection,
                store: fixPlanStore
            )
        } catch {
            if isMissingPlan(error) {
                return await conflictResult()
            }
            return await failureResult(error, projection: projection)
        }
    }

    private func handleValidatedCommand(
        _ command: UserIntentCommand,
        target: FixPlanCommandTarget,
        decision: FixPlanReviewDecision,
        projection: FixPlanProjection,
        store: any FixPlanStore
    ) async throws -> UserCommandResult {
        if command.kind == .applyFixPlan {
            return await applyPlan(target: target, decision: decision, projection: projection)
        }
        switch await resolveDecisionUpdate(for: command, current: decision, projection: projection) {
        case let .update(nextDecision):
            return try await recordDecision(nextDecision, in: store)
        case let .result(result):
            return result
        }
    }

    private func isMissingPlan(_ error: any Error) -> Bool {
        guard let error = error as? FixPlanPersistenceError else { return false }
        if case .missingPlan = error {
            return true
        }
        return false
    }

    private func isFixPlanCommand(_ kind: UserIntentCommandKind) -> Bool {
        switch kind {
        case .acceptFixPlan,
             .applyFixPlan,
             .rejectFixPlan,
             .togglePlanItem:
            true
        case .reviewChanges,
             .resumeRecovery,
             .runManually:
            false
        }
    }

    private func targetMatchesProjection(
        _ target: FixPlanCommandTarget,
        in projection: FixPlanProjection
    ) -> Bool {
        projection.planID == target.planID &&
            projection.planRevision == target.planRevision &&
            projection.decisionRevision == target.decisionRevision &&
            projection.revision == target.projectionRevision
    }

    private func decisionUpdate(
        for command: UserIntentCommand,
        current decision: FixPlanReviewDecision
    ) -> DecisionUpdate {
        switch command.kind {
        case .acceptFixPlan:
            if decision.itemDecisions.allSatisfy({ $0.verdict == .accepted }) {
                return .noOp
            }
            return .changed(FixPlanReviewer.acceptingAll(decision, at: now()))
        case .rejectFixPlan:
            if decision.itemDecisions.allSatisfy({ $0.verdict == .rejected }) {
                return .noOp
            }
            return .changed(FixPlanReviewer.rejectingAll(decision, at: now()))
        case .togglePlanItem:
            guard let itemID = command.targetItemID,
                  let nextDecision = FixPlanReviewer.togglingItem(itemID, in: decision, at: now())
            else {
                return .unavailableItem
            }
            return .changed(nextDecision)
        case .applyFixPlan,
             .reviewChanges,
             .resumeRecovery,
             .runManually:
            return .unavailableItem
        }
    }

    private func resolveDecisionUpdate(
        for command: UserIntentCommand,
        current decision: FixPlanReviewDecision,
        projection: FixPlanProjection
    ) async -> DecisionResolution {
        switch decisionUpdate(for: command, current: decision) {
        case let .changed(nextDecision):
            return .update(nextDecision)
        case .noOp:
            let result = await noOpResult(projection: projection)
            return .result(result)
        case .unavailableItem:
            let result = await staleResult(message: "Review item is no longer available.", projection: projection)
            return .result(result)
        }
    }

    private func recordDecision(
        _ nextDecision: FixPlanReviewDecision,
        in fixPlanStore: any FixPlanStore
    ) async throws -> UserCommandResult {
        switch try await fixPlanStore.recordDecision(nextDecision) {
        case .saved:
            let refreshedFixPlan = await refreshFixPlanProjection()
            let refreshedActivity = await refreshActivityProjection()
            return .accepted(
                message: "Review updated.",
                refreshedActivityProjection: refreshedActivity,
                refreshedFixPlanProjection: refreshedFixPlan
            )
        case .conflict:
            return await conflictResult()
        }
    }

    private func applyPlan(
        target: FixPlanCommandTarget,
        decision: FixPlanReviewDecision,
        projection: FixPlanProjection
    ) async -> UserCommandResult {
        guard decision.itemDecisions.contains(where: { $0.verdict == .accepted }) else {
            return await noAcceptedResult(projection: projection)
        }
        guard projection.canApply else {
            return await staleResult(message: "Fix plan changed. Refreshing current plan.", projection: projection)
        }
        if await hasRecoveryHold() {
            return await recoveryHoldResult(target: target, projection: projection)
        }

        do {
            let result = try await submitFixPlanWrite(target.writeTarget)
            return await writeResult(result, fallbackAcceptedCount: projection.acceptedCount)
        } catch {
            return await writeFailureResult(error, projection: projection)
        }
    }

    private func writeResult(
        _ result: RunSubmissionResult,
        fallbackAcceptedCount: Int
    ) async -> UserCommandResult {
        let refreshedFixPlan = await refreshFixPlanProjection()
        let refreshedActivity = await refreshActivityProjection()
        switch result {
        case .alreadyCovered:
            return .alreadyCovered(
                message: "A write run is already active.",
                refreshedActivityProjection: refreshedActivity
            )
        case .queued:
            return .queued(
                message: "Write run queued after current run.",
                refreshedActivityProjection: refreshedActivity
            )
        case let .completed(snapshot):
            let changeCount = snapshot.syncResult?.changeCount ?? fallbackAcceptedCount
            return .accepted(
                message: "Applied \(changeCount) \(changeLabel(for: changeCount)).",
                refreshedActivityProjection: refreshedActivity,
                refreshedFixPlanProjection: refreshedFixPlan
            )
        case .completedNoOp:
            return .noOp(
                message: "Accepted changes are already up to date.",
                refreshedActivityProjection: refreshedActivity,
                refreshedFixPlanProjection: refreshedFixPlan
            )
        case .cancelled:
            return .noOp(
                message: "Write run cancelled.",
                refreshedActivityProjection: refreshedActivity,
                refreshedFixPlanProjection: refreshedFixPlan
            )
        case let .failed(snapshot):
            return .requiresAttention(
                message: "Write run failed.",
                issue: OperationalIssue(
                    id: "fix-plan-write-failed",
                    category: .internalFailure,
                    summary: "Write run failed",
                    technicalDetail: snapshot.failureMessage
                ),
                refreshedActivityProjection: refreshedActivity,
                refreshedFixPlanProjection: refreshedFixPlan
            )
        }
    }

    private func changeLabel(for count: Int) -> String {
        count == 1 ? "change" : "changes"
    }

    private func noAcceptedResult(projection: FixPlanProjection) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .noOp(
            message: "No accepted changes to apply.",
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }

    private func recoveryHoldResult(
        target: FixPlanCommandTarget,
        projection _: FixPlanProjection
    ) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .blockedByRecovery(
            message: "Recovery must be resolved before writes continue.",
            issue: OperationalIssue(
                id: "fix-plan-write-held",
                category: .recoveryRequired,
                summary: "Write held by recovery",
                technicalDetail: target.planID.description
            ),
            refreshedActivityProjection: activity
        )
    }

    private func writeFailureResult(
        _ error: any Error,
        projection: FixPlanProjection
    ) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .requiresAttention(
            message: "Write run failed.",
            issue: OperationalIssue(
                id: "fix-plan-write-failed",
                category: .internalFailure,
                summary: "Write run failed",
                technicalDetail: error.localizedDescription
            ),
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }

    private func noOpResult(projection: FixPlanProjection) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .noOp(
            message: "Review already up to date.",
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }

    private func conflictResult() async -> UserCommandResult {
        let projection = await refreshFixPlanProjection()
        return await staleResult(
            message: "Review changed. Refreshing current plan.",
            projection: projection
        )
    }

    private func staleResult(
        message: String,
        projection: FixPlanProjection
    ) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .rejectedStale(
            message: message,
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }

    private func invalidCommand(_ command: UserIntentCommand) async -> UserCommandResult {
        let projection = await refreshFixPlanProjection()
        return await invalidTargetResult(
            detail: "Unsupported command kind: \(command.kind.rawValue)",
            projection: projection
        )
    }

    private func invalidTargetResult(detail: String, projection: FixPlanProjection) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .rejectedInvalid(
            message: "Review action is unavailable.",
            issue: OperationalIssue(
                id: "fix-plan-command-invalid",
                category: .staleAction,
                summary: "Review action unavailable",
                technicalDetail: detail
            ),
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }

    private func unavailableStoreResult(target: FixPlanCommandTarget) async -> UserCommandResult {
        let projection = await refreshFixPlanProjection()
        let activity = await refreshActivityProjection()
        return .temporaryUnavailable(
            message: "Review storage is unavailable.",
            issue: OperationalIssue(
                id: "fix-plan-store-unavailable",
                category: .temporaryUnavailable,
                summary: "Review storage unavailable",
                technicalDetail: target.planID.description
            ),
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }

    private func failureResult(_ error: any Error, projection: FixPlanProjection) async -> UserCommandResult {
        let activity = await refreshActivityProjection()
        return .requiresAttention(
            message: "Review update failed.",
            issue: OperationalIssue(
                id: "fix-plan-review-failed",
                category: .internalFailure,
                summary: "Review update failed",
                technicalDetail: error.localizedDescription
            ),
            refreshedActivityProjection: activity,
            refreshedFixPlanProjection: projection
        )
    }
}
