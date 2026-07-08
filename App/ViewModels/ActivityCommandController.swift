import Foundation
import OSLog
import Services

@MainActor
struct ActivityCommandController {
    private let log = Logger(subsystem: "com.genreupdater", category: "ActivityCommands")

    let isRunOrchestratorAvailable: () -> Bool
    let submitManualRun: () async throws -> RunSubmissionResult
    let reloadLibrary: (_ forceRefresh: Bool) async -> Void
    let refreshActivityProjection: () async -> ActivityProjection
    let runRecoveryPreflight: (RunID) async -> RecoveryPreflightOutcome
    let currentFixPlanID: () -> String?

    static func command(for descriptor: ActivityCommandDescriptor?) -> UserIntentCommand? {
        guard let descriptor, descriptor.isEnabled else { return nil }
        switch descriptor.commandKind {
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
        guard let secondaryCommand = projection.secondaryCommand,
              secondaryCommand.commandKind == .runManually
        else {
            return .rejectedStale(
                message: "Manual check is no longer available.",
                refreshedActivityProjection: projection
            )
        }
        guard secondaryCommand.isEnabled else {
            return .rejectedStale(
                message: "Manual check is no longer available.",
                refreshedActivityProjection: projection
            )
        }

        do {
            let result = try await submitManualRun()
            return await makeManualRunResult(result)
        } catch {
            log.error("""
            Manual observation run submission failed with \
            \(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private)
            """)
            let refreshedProjection = await refreshActivityProjection()
            return .requiresAttention(
                message: "Manual check failed.",
                issue: OperationalIssue(
                    id: "manual-check-failed",
                    category: .internalFailure,
                    summary: "Manual check failed",
                    technicalDetail: error.localizedDescription
                ),
                refreshedActivityProjection: refreshedProjection
            )
        }
    }

    private func recoveryIssue(in projection: ActivityProjection) -> OperationalIssue? {
        projection.operationalIssues.first { $0.category == .recoveryRequired }
    }

    private func libraryBlocker(in projection: ActivityProjection) -> OperationalIssue? {
        projection.operationalIssues.first { issue in
            switch issue.category {
            case .temporaryUnavailable, .musicPermissionRequired, .musicUnavailable, .musicKitUnavailable:
                true
            case .permissionRequired, .configurationRequired, .recoveryRequired, .safetyBlocked, .staleAction,
                 .internalFailure, .automationPermissionRequired, .applicationScriptsUnavailable,
                 .appleScriptWriteUnavailable:
                false
            }
        }
    }

    private func makeManualRunResult(_ result: RunSubmissionResult) async -> UserCommandResult {
        switch result {
        case .alreadyCovered:
            let projection = await refreshActivityProjection()
            return .alreadyCovered(
                message: "A run is already active.",
                refreshedActivityProjection: projection
            )
        case .queued:
            let projection = await refreshActivityProjection()
            return .queued(
                message: "Manual check queued after current run.",
                refreshedActivityProjection: projection
            )
        case let .completed(snapshot):
            await reloadLibrary(true)
            let projection = await refreshActivityProjection()
            let changeCount = snapshot.syncResult?.changeCount ?? 0
            let changeLabel = changeCount == 1 ? "change" : "changes"
            return .accepted(
                message: "Library delta detected · analyzing \(changeCount) \(changeLabel).",
                refreshedActivityProjection: projection
            )
        case .completedNoOp:
            await reloadLibrary(true)
            let projection = await refreshActivityProjection()
            return .noOp(
                message: "No library changes detected.",
                refreshedActivityProjection: projection
            )
        case let .failed(snapshot):
            let projection = await refreshActivityProjection()
            return .requiresAttention(
                message: "Manual check failed.",
                issue: OperationalIssue(
                    id: "manual-check-failed",
                    category: .temporaryUnavailable,
                    summary: "Manual check failed",
                    technicalDetail: snapshot.failureMessage
                ),
                refreshedActivityProjection: projection
            )
        }
    }
}
