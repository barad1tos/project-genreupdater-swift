import Services

@MainActor
struct ActivityCommandController {
    let currentProjection: () -> ActivityProjection
    let isSynchronizingLibrary: () -> Bool
    let isLibrarySyncAvailable: () -> Bool
    let setSynchronizingLibrary: (Bool) -> Void
    let setLastSyncResult: (SyncResult?) -> Void
    let setSyncErrorMessage: (String?) -> Void
    let synchronizeLibraryNow: () async throws -> SyncResult
    let reloadLibrary: (_ forceRefresh: Bool) async -> Void
    let refreshActivityProjection: () async -> ActivityProjection

    func handle(_ command: UserIntentCommand) async -> UserCommandResult {
        switch command.kind {
        case .reviewChanges:
            let projection = await refreshActivityProjection()
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
                navigationTarget: .fixPlan(id: "current"),
                refreshedActivityProjection: projection
            )
        case .runManually:
            return await handleRunManually()
        }
    }

    private func handleRunManually() async -> UserCommandResult {
        if isSynchronizingLibrary() {
            return .alreadyCovered(
                message: "A library sync is already running.",
                refreshedActivityProjection: currentProjection()
            )
        }

        guard isLibrarySyncAvailable() else {
            let projection = await refreshActivityProjection()
            return .temporaryUnavailable(
                message: "Library sync service is unavailable.",
                issue: OperationalIssue(
                    id: "library-sync-unavailable",
                    category: .temporaryUnavailable,
                    summary: "Library sync unavailable",
                    technicalDetail: "AppDependencies.librarySyncService is nil"
                ),
                refreshedActivityProjection: projection
            )
        }

        let projection = await refreshActivityProjection()
        guard projection.secondaryCommand?.commandKind == .runManually,
              projection.secondaryCommand?.isEnabled == true
        else {
            return .rejectedStale(
                message: "Manual sync is no longer available.",
                refreshedActivityProjection: projection
            )
        }
        if isSynchronizingLibrary() {
            return .alreadyCovered(
                message: "A library sync is already running.",
                refreshedActivityProjection: projection
            )
        }

        setSynchronizingLibrary(true)
        setSyncErrorMessage(nil)
        _ = await refreshActivityProjection()

        do {
            let result = try await synchronizeLibraryNow()
            return await handleSyncSuccess(result)
        } catch {
            return await handleSyncFailure(error)
        }
    }

    private func handleSyncSuccess(_ result: SyncResult) async -> UserCommandResult {
        setLastSyncResult(result)
        await reloadLibrary(true)
        setSynchronizingLibrary(false)
        let projection = await refreshActivityProjection()
        let changeCount = result.changeCount

        if changeCount == 0 {
            return .noOp(
                message: "No library changes detected.",
                refreshedActivityProjection: projection
            )
        }

        let changeLabel = changeCount == 1 ? "change" : "changes"
        return .accepted(
            message: "Library delta detected · analyzing \(changeCount) \(changeLabel).",
            refreshedActivityProjection: projection
        )
    }

    private func handleSyncFailure(_ error: Error) async -> UserCommandResult {
        setLastSyncResult(nil)
        setSyncErrorMessage(error.localizedDescription)
        setSynchronizingLibrary(false)
        let projection = await refreshActivityProjection()
        return .requiresAttention(
            message: "Library sync failed.",
            issue: OperationalIssue(
                id: "library-sync-failed",
                category: .temporaryUnavailable,
                summary: "Library sync failed",
                technicalDetail: error.localizedDescription
            ),
            refreshedActivityProjection: projection
        )
    }
}
