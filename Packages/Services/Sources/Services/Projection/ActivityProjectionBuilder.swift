import Foundation

public enum ActivityProjectionBuilder {
    public static func makeProjection(from input: ActivityProjectionInput) -> ActivityProjection {
        let counts = makeCounts(from: input)
        let syncSummary = input.effectiveSyncState.summary
        let currentStage = makeCurrentStage(input: input)
        let stageDescriptors = makeStageDescriptors(input: input, currentStage: currentStage, syncSummary: syncSummary)
        let issues = makeOperationalIssues(from: input)

        return ActivityProjection(
            revision: .initial,
            title: makeTitle(input: input),
            subtitle: makeSubtitle(input: input, syncSummary: syncSummary),
            syncStatusText: makeSyncStatusText(input: input),
            currentStage: currentStage,
            processingMode: input.processingMode,
            automationState: makeAutomationState(input: input),
            deltaCount: makeDeltaCount(input: input, syncSummary: syncSummary),
            interventionCount: input.pendingVerification?.total ?? 0,
            protectedCount: counts.protectedFileCount,
            failedWriteCount: input.workflow.failedWriteCount,
            isUndoReady: false,
            primaryCommand: makePrimaryCommand(input: input),
            secondaryCommand: makeRunManuallyCommand(input: input),
            stageDescriptors: stageDescriptors,
            recentActivity: makeRecentActivity(input: input, counts: counts, syncSummary: syncSummary),
            summaryCards: makeSummaryCards(input: input, counts: counts, syncSummary: syncSummary),
            operationalIssues: issues
        )
    }

    private static func makeDeltaCount(
        input: ActivityProjectionInput,
        syncSummary: ActivitySyncSummary?
    ) -> Int {
        if input.proposedFixCount > 0 {
            return input.proposedFixCount
        }
        return syncSummary?.changeCount ?? 0
    }

    struct Counts {
        let totalTracks: Int
        let tracksWithBoth: Int
        let protectedFileCount: Int
    }

    private static func makeCounts(from input: ActivityProjectionInput) -> Counts {
        if let metrics = input.metrics {
            return Counts(
                totalTracks: metrics.totalTracks,
                tracksWithBoth: metrics.tracksWithBoth,
                protectedFileCount: metrics.protectedFileCount ?? 0
            )
        }

        let tracksWithBoth = input.tracks.count { track in
            track.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && track.year != nil
        }
        return Counts(
            totalTracks: input.tracks.count,
            tracksWithBoth: tracksWithBoth,
            protectedFileCount: 0
        )
    }

    static func makeAutomationState(input: ActivityProjectionInput) -> ActivityAutomationState {
        if input.isAutoSyncRunning {
            return .autoSyncRunning
        }
        if input.effectiveLastScanDate != nil {
            return .manualScanOnly
        }
        return .noSyncYet
    }

    private static func makePrimaryCommand(input: ActivityProjectionInput) -> ActivityCommandDescriptor? {
        if input.hasRecovery, !hasLibraryBlocker(input: input) {
            return ActivityCommandDescriptor(
                id: "resume-recovery",
                title: "Resume safely",
                style: .primary,
                isEnabled: true,
                commandKind: .resumeRecovery
            )
        }

        guard !input.hasRecovery else { return nil }
        guard !input.effectiveSyncState.requiresRecoveryAttention else { return nil }
        guard input.proposedFixCount > 0 else { return nil }

        return ActivityCommandDescriptor(
            id: "review-changes",
            title: "Review changes",
            style: .primary,
            isEnabled: true,
            commandKind: .reviewChanges
        )
    }

    private static func makeRunManuallyCommand(input: ActivityProjectionInput) -> ActivityCommandDescriptor {
        let canQueue = input.runLifecycle?.canQueueManual == true
        let isEnabled = input.isLibrarySyncAvailable
            && !input.workflow.isProcessing
            && (input.effectiveSyncState != .running || canQueue)
        return ActivityCommandDescriptor(
            id: "run-manually",
            title: canQueue ? "Queue manual" : "Run manually",
            style: .secondary,
            isEnabled: isEnabled,
            commandKind: .runManually
        )
    }

    private static func makeOperationalIssues(from input: ActivityProjectionInput) -> [OperationalIssue] {
        if input.hasRecovery, !hasLibraryBlocker(input: input) {
            return [OperationalIssue(
                id: "recovery-needed",
                category: .recoveryRequired,
                summary: "Previous run needs recovery",
                technicalDetail: input.recovery?.latestRunID
            )]
        }

        if let issue = input.libraryState.operationalIssue {
            return [issue]
        }

        if let syncIssue = input.effectiveSyncState.operationalIssue {
            return [syncIssue]
        }
        return []
    }
}
