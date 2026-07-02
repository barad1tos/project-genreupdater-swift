import Core
import Foundation
import Services

struct ActivityProjectionAssemblyContext {
    let tracks: [Core.Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let lastScanDate: Date?
    let loadError: LibraryLoadError?
    let isLoading: Bool
    let isDryRun: Bool
    let workflow: WorkflowDashboardState
    let pendingVerification: UpdateRunPendingVerificationSummary?
    let lastSyncResult: SyncResult?
    let syncErrorMessage: String?
    let isSynchronizingLibrary: Bool
    let isLibrarySyncAvailable: Bool
    let isAutoSyncRunning: Bool
    let now: Date
}

enum ActivityProjectionInputAssembler {
    static func makeInput(from context: ActivityProjectionAssemblyContext) -> ActivityProjectionInput {
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
            pendingVerification: makePendingVerification(from: context.pendingVerification),
            syncState: makeSyncState(
                lastSyncResult: context.lastSyncResult,
                syncErrorMessage: context.syncErrorMessage,
                isSynchronizingLibrary: context.isSynchronizingLibrary
            ),
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

    private static func makeSyncState(
        lastSyncResult: SyncResult?,
        syncErrorMessage: String?,
        isSynchronizingLibrary: Bool
    ) -> ActivitySyncState {
        if isSynchronizingLibrary {
            return .running
        }
        if let syncErrorMessage {
            return .failed(syncErrorMessage)
        }
        if let lastSyncResult {
            return .completed(ActivitySyncSummary(
                new: lastSyncResult.newTracks.count,
                modified: lastSyncResult.modifiedTracks.count,
                identityChanged: lastSyncResult.identityChangedTracks.count,
                refreshed: lastSyncResult.refreshedTracks.count,
                removed: lastSyncResult.removedTrackIDs.count
            ))
        }
        return .idle
    }
}
