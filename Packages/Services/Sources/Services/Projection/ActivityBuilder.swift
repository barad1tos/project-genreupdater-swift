import Foundation

public enum ActivityBuilder {
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
            scanFacts: makeScanFacts(input: input),
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

    static func makeScanFacts(input: ActivityProjectionInput) -> ActivityScanFacts {
        ActivityScanFacts(
            lastScanLabel: makeLastScanLabel(input: input),
            nextRunLabel: makeNextRunLabel(input: input),
            albumCount: makeAlbumCount(input: input)
        )
    }

    private static func makeLastScanLabel(input: ActivityProjectionInput) -> String {
        guard let lastScanDate = input.effectiveLastScanDate else { return "No scan yet" }
        return relativeElapsedLabel(since: lastScanDate, now: input.now)
    }

    private static func makeNextRunLabel(input: ActivityProjectionInput) -> String {
        if let lifecycleLabel = makeRunLifecycleNextRunLabel(from: input.runLifecycle) {
            return lifecycleLabel
        }
        switch makeAutomationState(input: input) {
        case .autoSyncRunning:
            return "Auto-sync running"
        case .manualScanOnly, .noSyncYet:
            return "Manual scan only"
        }
    }

    private static func makeRunLifecycleNextRunLabel(from lifecycle: RunLifecycleSnapshot?) -> String? {
        guard let lifecycle else { return nil }

        switch lifecycle.phase {
        case .active:
            return lifecycle.trigger == .manualCheck ? "Manual sync running" : "Run in progress"
        case .suspended(.blocked):
            return lifecycle.trigger == .manualCheck ? "Manual sync blocked" : "Run blocked"
        case .suspended(.recoverable):
            return lifecycle.trigger == .manualCheck ? "Manual sync needs recovery" : "Recovery needed"
        case .finished(.failed, _):
            return lifecycle.trigger == .manualCheck ? "Manual sync failed" : "Run failed"
        case .finished(.cancelled, _):
            return lifecycle.trigger == .manualCheck ? "Manual sync cancelled" : "Run cancelled"
        case .finished(.completed, _), .finished(.completedNoOp, _):
            return nil
        }
    }

    private static func makeAlbumCount(input: ActivityProjectionInput) -> Int? {
        guard !input.tracks.isEmpty else {
            // nil = metrics-backed snapshot without album identity; 0 = no
            // cached metrics and no live tracks.
            return input.metrics == nil ? 0 : nil
        }
        return Set(input.tracks.map(\.albumIdentity)).count
    }

    /// Shared relative-elapsed vocabulary for scan labels; public so the
    /// App-side report mapping speaks the same buckets.
    public static func relativeElapsedLabel(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))

        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m ago"
        }
        if seconds < 86400 {
            return "\(seconds / 3600)h ago"
        }
        return "\(seconds / 86400)d ago"
    }

    private static func makePrimaryCommand(input: ActivityProjectionInput) -> ActivityCommandDescriptor? {
        if shouldShowRecoveryNotice(input: input) {
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
        // A retained write outranks a new review: the user's queued intent
        // resolves first, and only through this explicit command (ADR 0006).
        if input.queuedWrite != nil, canSurfaceRecovery(input: input) {
            return ActivityCommandDescriptor(
                id: "continue-writes",
                title: "Continue writes",
                style: .primary,
                isEnabled: true,
                commandKind: .continueWrites
            )
        }
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
        let isLibraryCheck = shouldShowLibraryCheck(input: input)
        let isEnabled = input.isLibrarySyncAvailable
            && !input.workflow.isProcessing
            && (input.effectiveSyncState != .running || canQueue)
        return ActivityCommandDescriptor(
            id: "run-manually",
            title: makeManualTitle(canQueue: canQueue, isLibraryCheck: isLibraryCheck),
            style: .secondary,
            isEnabled: isEnabled,
            commandKind: .runManually,
            variant: isLibraryCheck ? .libraryCheck : .standard
        )
    }

    private static func shouldShowLibraryCheck(input: ActivityProjectionInput) -> Bool {
        canSurfaceRecovery(input: input)
            && (input.hasRecovery || input.effectiveSyncState.requiresRecoveryAttention)
    }

    private static func shouldShowRecoveryNotice(input: ActivityProjectionInput) -> Bool {
        canSurfaceRecovery(input: input) && input.hasRecovery
    }

    private static func canSurfaceRecovery(input: ActivityProjectionInput) -> Bool {
        !hasLibraryBlocker(input: input)
    }

    private static func makeManualTitle(canQueue: Bool, isLibraryCheck: Bool) -> String {
        if isLibraryCheck {
            if canQueue {
                return "Queue library check"
            }
            return "Check library"
        }
        if canQueue {
            return "Queue manual"
        }
        return "Run manually"
    }

    private static func makeOperationalIssues(from input: ActivityProjectionInput) -> [OperationalIssue] {
        if shouldShowRecoveryNotice(input: input) {
            return [OperationalIssue(
                id: "recovery-needed",
                category: .recoveryRequired,
                summary: "Previous run needs recovery",
                technicalDetail: input.recovery?.latestRecoveryRunID
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
