import Core
import Foundation
import Services

struct ActivityInputContext {
    let tracks: [Core.Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let lastScanDate: Date?
    let loadError: LibraryLoadError?
    let isLoading: Bool
    let isDryRun: Bool
    let workflow: WorkflowDashboardState
    let fixPlanProjection: FixPlanProjection
    let pendingVerification: UpdateRunPendingVerificationSummary?
    let runLifecycle: RunLifecycleSnapshot?
    let isLibrarySyncAvailable: Bool
    let isAutoSyncRunning: Bool
    let now: Date
}

enum ActivityInputBuilder {
    static func makeInput(from context: ActivityInputContext) -> ActivityProjectionInput {
        ActivityProjectionInput(
            tracks: context.tracks,
            metrics: makeMetrics(from: context.metricsSnapshot),
            lastScanDate: context.lastScanDate,
            libraryState: makeLibraryState(
                loadError: context.loadError,
                isLoading: context.isLoading,
                tracks: context.tracks
            ),
            processingMode: context.isDryRun ? .preview : .autoFix,
            workflow: makeWorkflowState(from: context.workflow),
            fixPlan: makeFixPlanSummary(from: context.fixPlanProjection),
            pendingVerification: makePendingVerification(from: context.pendingVerification),
            runLifecycle: context.runLifecycle,
            isLibrarySyncAvailable: context.isLibrarySyncAvailable,
            isAutoSyncRunning: context.isAutoSyncRunning,
            now: context.now
        )
    }

    private static func makeMetrics(from metricsSnapshot: PersistedMetricsSnapshot?) -> ActivityProjectionMetrics? {
        guard let metricsSnapshot else { return nil }
        return ActivityProjectionMetrics(
            totalTracks: metricsSnapshot.totalTracks,
            tracksWithGenre: metricsSnapshot.tracksWithGenre,
            tracksWithYear: metricsSnapshot.tracksWithYear,
            tracksWithBoth: metricsSnapshot.tracksWithBoth,
            protectedFileCount: metricsSnapshot.protectedFileCount,
            recentlyAdded: metricsSnapshot.recentlyAdded,
            snapshotDate: metricsSnapshot.timestamp
        )
    }

    private static func makeLibraryState(
        loadError: LibraryLoadError?,
        isLoading: Bool,
        tracks: [Core.Track]
    ) -> ActivityLibraryState {
        if let loadError {
            switch loadError {
            case .permissionDenied:
                return .permissionDenied(loadError.message)
            case .restricted, .failed:
                return .failed(loadError.message)
            }
        }
        if isLoading {
            return .loading
        }
        return tracks.isEmpty ? .empty : .ready
    }

    private static func makeWorkflowState(from workflow: WorkflowDashboardState) -> ActivityWorkflowState {
        ActivityWorkflowState(
            proposedChangeCount: workflow.proposedChangeCount,
            acceptedChangeCount: workflow.acceptedChangeCount,
            failedWriteCount: workflow.failedWriteCount,
            isProcessing: workflow.isProcessing,
            phaseLabel: workflow.phaseLabel
        )
    }

    private static func makeFixPlanSummary(from projection: FixPlanProjection) -> ActivityFixPlanSummary? {
        guard projection.status != .empty else { return nil }
        return ActivityFixPlanSummary(projection: projection)
    }

    private static func makePendingVerification(
        from summary: UpdateRunPendingVerificationSummary?
    ) -> ActivityPendingVerificationSummary? {
        guard let summary else { return nil }
        return ActivityPendingVerificationSummary(
            total: summary.total,
            due: summary.due,
            problematic: summary.problematic,
            skippedByInterval: summary.skippedByInterval,
            verified: summary.verified
        )
    }
}
