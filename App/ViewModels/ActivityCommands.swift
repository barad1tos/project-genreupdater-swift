import Foundation
import OSLog
import Services

@MainActor
struct ActivityCommands {
    private let log = Logger(subsystem: "com.genreupdater", category: "ActivityCommands")

    let isRunOrchestratorAvailable: () -> Bool
    let submitManualRun: () async throws -> RunSubmissionResult
    let queueManualReload: (RunID) -> Void
    let reloadLibrary: (_ forceRefresh: Bool) async -> Void
    let refreshActivityProjection: () async -> ActivityProjection
    let runRecoveryPreflight: (RunID) async -> RecoveryPreflightOutcome
    let currentFixPlanID: () -> String?

    static func command(for descriptor: ActivityCommandDescriptor?) -> UserIntentCommand? {
        guard let descriptor, descriptor.isEnabled else { return nil }
        switch descriptor.commandKind {
        case .acceptFixPlan,
             .rejectFixPlan,
             .togglePlanItem:
            // Fix-plan actions route through FixPlanCommands; Activity keeps these cases exhaustive.
            return nil
        case .reviewChanges:
            return .reviewChanges()
        case .resumeRecovery:
            return .resumeRecovery()
        case .runManually:
            return .runManually()
        }
    }

    func handle(_ command: UserIntentCommand) async -> UserCommandResult {
        switch command.kind {
        case .acceptFixPlan,
             .rejectFixPlan,
             .togglePlanItem:
            // Defensive only: Activity descriptors never construct fix-plan commands.
            return await unavailableFixPlanCommand(command)
        case .reviewChanges:
            let projection = await refreshActivityProjection()
            if let issue = recoveryIssue(in: projection) {
                return .blockedByRecovery(
                    message: "Previous run needs recovery before writes continue.",
                    issue: issue,
                    refreshedActivityProjection: projection
                )
            }
            guard projection.primaryCommand?.commandKind == .reviewChanges,
                  projection.primaryCommand?.isEnabled == true
            else {
                return .rejectedStale(
                    message: "Review plan is no longer available.",
                    refreshedActivityProjection: projection
                )
            }
            return UserCommandResult.navigated(
                message: "Opening review.",
                navigationTarget: .fixPlan(id: currentFixPlanID() ?? "current"),
                refreshedActivityProjection: projection
            )
        case .resumeRecovery:
            let projection = await refreshActivityProjection()
            if let blocker = libraryBlocker(in: projection) {
                return .temporaryUnavailable(
                    message: blocker.summary,
                    issue: blocker,
                    refreshedActivityProjection: projection
                )
            }
            guard let issue = recoveryIssue(in: projection),
                  projection.primaryCommand?.commandKind == .resumeRecovery,
                  projection.primaryCommand?.isEnabled == true
            else {
                return .rejectedStale(
                    message: "Recovery is no longer required.",
                    refreshedActivityProjection: projection
                )
            }
            guard let runID = recoveryRunID(from: issue) else {
                return malformedRecoveryResult(projection: projection, issue: issue)
            }
            let outcome = await runRecoveryPreflight(runID)
            return makeRecoveryResult(outcome, projection: projection)
        case .runManually:
            return await handleRunManually()
        }
    }

    private func unavailableFixPlanCommand(_ command: UserIntentCommand) async -> UserCommandResult {
        let projection = await refreshActivityProjection()
        return .rejectedInvalid(
            message: "Fix plan action is unavailable from Activity.",
            issue: OperationalIssue(
                id: "fix-plan-command-unavailable",
                category: .staleAction,
                summary: "Fix plan action unavailable",
                technicalDetail: command.kind.rawValue
            ),
            refreshedActivityProjection: projection
        )
    }

    private func recoveryRunID(from issue: OperationalIssue) -> RunID? {
        guard let rawID = issue.technicalDetail,
              let uuid = UUID(uuidString: rawID)
        else { return nil }

        return RunID(rawValue: uuid)
    }

    private func makeRecoveryResult(
        _ outcome: RecoveryPreflightOutcome,
        projection: ActivityProjection
    ) -> UserCommandResult {
        switch outcome {
        case let .inspectable(runID, _):
            return .navigated(
                message: "Opening recovery.",
                navigationTarget: .recovery(runID: runID.rawValue.uuidString),
                refreshedActivityProjection: projection
            )
        case .resolved:
            return .noOp(
                message: "Recovery is no longer required.",
                refreshedActivityProjection: projection
            )
        case let .needsAttention(_, reason):
            let detail: String = switch reason {
            case let .writeAdjacentState(state): state.rawValue
            case let .unresolvedState(state): state.rawValue
            }
            return .requiresAttention(
                message: "Recovery needs review.",
                issue: OperationalIssue(
                    id: "recovery-needs-attention",
                    category: .safetyBlocked,
                    summary: "Recovery needs review",
                    technicalDetail: detail
                ),
                refreshedActivityProjection: projection
            )
        case .blocked:
            return .requiresAttention(
                message: "Recovery preflight is unavailable.",
                issue: OperationalIssue(
                    id: "recovery-preflight-blocked",
                    category: .temporaryUnavailable,
                    summary: "Recovery preflight unavailable",
                    technicalDetail: nil
                ),
                refreshedActivityProjection: projection
            )
        }
    }

    private func malformedRecoveryResult(
        projection: ActivityProjection,
        issue: OperationalIssue
    ) -> UserCommandResult {
        .requiresAttention(
            message: "Recovery record is unavailable.",
            issue: OperationalIssue(
                id: "recovery-record-unavailable",
                category: .recoveryRequired,
                summary: "Recovery record unavailable",
                technicalDetail: issue.technicalDetail
            ),
            refreshedActivityProjection: projection
        )
    }

    private func handleRunManually() async -> UserCommandResult {
        guard isRunOrchestratorAvailable() else {
            let projection = await refreshActivityProjection()
            return .temporaryUnavailable(
                message: "Run orchestration is unavailable.",
                issue: OperationalIssue(
                    id: "run-orchestrator-unavailable",
                    category: .temporaryUnavailable,
                    summary: "Run orchestration unavailable",
                    technicalDetail: "AppDependencies.runOrchestrator is nil"
                ),
                refreshedActivityProjection: projection
            )
        }

        let projection = await refreshActivityProjection()
        guard let secondaryCommand = projection.secondaryCommand else {
            // Builder projections always include the secondary command; standard copy is a defensive default.
            return unavailableRunResult(projection: projection, copy: runCommandCopy(for: .standard))
        }
        let copy = runCommandCopy(for: secondaryCommand.variant)
        guard secondaryCommand.commandKind == .runManually else {
            return unavailableRunResult(projection: projection, copy: copy)
        }
        guard secondaryCommand.isEnabled else {
            return unavailableRunResult(projection: projection, copy: copy)
        }

        do {
            let result = try await submitManualRun()
            return await makeManualRunResult(result, copy: copy)
        } catch {
            log.error("""
            \(copy.failedSummary, privacy: .public) submission failed with \
            \(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private)
            """)
            let refreshedProjection = await refreshActivityProjection()
            return .requiresAttention(
                message: copy.failedMessage,
                issue: OperationalIssue(
                    id: copy.failedIssueID,
                    category: .internalFailure,
                    summary: copy.failedSummary,
                    technicalDetail: error.localizedDescription
                ),
                refreshedActivityProjection: refreshedProjection
            )
        }
    }

    private func unavailableRunResult(
        projection: ActivityProjection,
        copy: RunCommandCopy
    ) -> UserCommandResult {
        .rejectedStale(
            message: copy.unavailable,
            refreshedActivityProjection: projection
        )
    }

    private func recoveryIssue(in projection: ActivityProjection) -> OperationalIssue? {
        projection.operationalIssues.first { $0.category == .recoveryRequired }
    }

    private func libraryBlocker(in projection: ActivityProjection) -> OperationalIssue? {
        projection.operationalIssues.first { issue in
            switch issue.category {
            case .temporaryUnavailable,
                 .musicPermissionRequired,
                 .musicUnavailable,
                 .musicKitUnavailable:
                true
            case .permissionRequired,
                 .configurationRequired,
                 .recoveryRequired,
                 .safetyBlocked,
                 .staleAction,
                 .internalFailure,
                 .automationPermissionRequired,
                 .applicationScriptsUnavailable,
                 .appleScriptWriteUnavailable:
                false
            }
        }
    }

    private func makeManualRunResult(
        _ result: RunSubmissionResult,
        copy: RunCommandCopy
    ) async -> UserCommandResult {
        switch result {
        case .alreadyCovered:
            let projection = await refreshActivityProjection()
            return .alreadyCovered(
                message: copy.alreadyActive,
                refreshedActivityProjection: projection
            )
        case let .queued(activeRun):
            queueManualReload(activeRun.runID)
            let projection = await refreshActivityProjection()
            return .queued(
                message: copy.queued,
                refreshedActivityProjection: projection
            )
        case let .completed(snapshot):
            // Read-only view refresh; metadata writes remain gated by the observe-only run.
            await reloadLibrary(true)
            let projection = await refreshActivityProjection()
            let changeCount = snapshot.syncResult?.changeCount ?? 0
            return .accepted(
                message: copy.completedMessage(changeCount: changeCount),
                refreshedActivityProjection: projection
            )
        case .completedNoOp:
            // Read-only view refresh; metadata writes remain gated by the observe-only run.
            await reloadLibrary(true)
            let projection = await refreshActivityProjection()
            return .noOp(
                message: copy.noChanges,
                refreshedActivityProjection: projection
            )
        case .cancelled:
            let projection = await refreshActivityProjection()
            return .noOp(
                message: copy.cancelled,
                refreshedActivityProjection: projection
            )
        case let .failed(snapshot):
            let projection = await refreshActivityProjection()
            return .requiresAttention(
                message: copy.failedMessage,
                issue: OperationalIssue(
                    id: copy.failedIssueID,
                    category: .temporaryUnavailable,
                    summary: copy.failedSummary,
                    technicalDetail: snapshot.failureMessage
                ),
                refreshedActivityProjection: projection
            )
        }
    }

    private func runCommandCopy(for variant: ActivityCommandVariant) -> RunCommandCopy {
        switch variant {
        case .standard:
            RunCommandCopy(
                alreadyActive: "A run is already active.",
                queued: "Manual check queued after current run.",
                unavailable: "Manual check is no longer available.",
                cancelled: "Manual check cancelled.",
                noChanges: "No library changes detected.",
                failedSummary: "Manual check failed",
                failedIssueID: "manual-check-failed",
                completed: .standard
            )
        case .libraryCheck:
            // Manual runs are observe-only; builder/app tests pin hold eligibility and copy.
            RunCommandCopy(
                alreadyActive: "A library check is already active · writes remain held.",
                queued: "Library check queued after current run.",
                unavailable: "Library check is no longer available.",
                cancelled: "Library check cancelled · writes remain held.",
                noChanges: "No library changes detected · writes remain held.",
                failedSummary: "Library check failed",
                failedIssueID: "library-check-failed",
                completed: .libraryCheck
            )
        }
    }

    private struct RunCommandCopy {
        let alreadyActive: String
        let queued: String
        let unavailable: String
        let cancelled: String
        let noChanges: String
        let failedSummary: String
        let failedIssueID: String
        let completed: CompletedRunCopy

        var failedMessage: String {
            "\(failedSummary)."
        }

        func completedMessage(changeCount: Int) -> String {
            completed.message(changeCount: changeCount)
        }
    }

    private enum CompletedRunCopy {
        case standard
        case libraryCheck

        func message(changeCount: Int) -> String {
            let changeLabel = changeCount == 1 ? "change" : "changes"
            switch self {
            case .standard:
                return "Library delta detected · analyzing \(changeCount) \(changeLabel)."
            case .libraryCheck:
                return "Library check found \(changeCount) \(changeLabel) · writes remain held."
            }
        }
    }
}
