import Core
import Foundation
import Services

/// Library facts the host still owns this slice (D5: the load chain
/// moves in slice 11); grouped below the parameter ceiling.
struct ActivityLibraryFacts {
    let tracks: [Core.Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let lastScanDate: Date?
    let loadError: LibraryLoadError?
    let isLoading: Bool
}

/// Workflow view-model facts, marked inputs until slice 11 moves
/// ownership behind the run orchestrator.
struct ActivityWorkflowFacts {
    let dashboard: WorkflowDashboardState
    let pendingVerification: UpdateRunPendingVerificationSummary?
}

struct ActivityInputContext {
    let tracks: [Core.Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let lastScanDate: Date?
    let loadError: LibraryLoadError?
    let isLoading: Bool
    let isDryRun: Bool
    let workflow: WorkflowDashboardState
    let fixPlanProjection: FixPlanProjection
    let reportsProjection: ReportsProjection
    let queuedWrite: ActivityQueuedWriteSummary?
    let pendingVerification: UpdateRunPendingVerificationSummary?
    let runLifecycle: RunLifecycleSnapshot?
    let isLibrarySyncAvailable: Bool
    let isAutoSyncRunning: Bool
    let now: Date
}

/// Backend-owned activity assembly (ADR 0013): the host supplies the
/// facts it still loads; projections, queued-write truth, and
/// MainActor configuration are read here — and the publish happens
/// here, never in view code.
extension AppDependencies {
    @discardableResult
    func refreshActivityProjection(
        library: ActivityLibraryFacts,
        workflow: ActivityWorkflowFacts,
        runLifecycle: RunLifecycleSnapshot?
    ) async -> ActivityProjection {
        // Synchronous MainActor facts first so the snapshot cannot tear
        // across the awaits below (D3).
        let isDryRun = config.runtime.dryRun
        let isLibrarySyncAvailable = isManualRunAvailable
        let isAutoSyncRunningNow = isAutoSyncRunning

        let inputGeneration = await projectionStore.nextActivityProjectionInputGeneration()
        let queuedWrite = await queuedWriteSummary()
        let fixPlan = await projectionStore.fixPlanProjection()
        let reports = await projectionStore.reportsProjection()

        let input = ActivityInputBuilder.makeInput(from: ActivityInputContext(
            tracks: library.tracks,
            metricsSnapshot: library.metricsSnapshot,
            lastScanDate: library.lastScanDate,
            loadError: library.loadError,
            isLoading: library.isLoading,
            isDryRun: isDryRun,
            workflow: workflow.dashboard,
            fixPlanProjection: fixPlan,
            reportsProjection: reports,
            queuedWrite: queuedWrite,
            pendingVerification: workflow.pendingVerification,
            runLifecycle: runLifecycle,
            isLibrarySyncAvailable: isLibrarySyncAvailable,
            isAutoSyncRunning: isAutoSyncRunningNow,
            now: Date()
        ))
        return await projectionStore.replaceActivityProjection(
            ActivityBuilder.makeProjection(from: input),
            inputGeneration: inputGeneration
        )
    }
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
            recovery: makeRecoverySummary(from: context.reportsProjection),
            queuedWrite: context.queuedWrite,
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

    private static func makeRecoverySummary(from projection: ReportsProjection) -> ActivityRecoverySummary? {
        guard !projection.recoveryRunIDs.isEmpty else { return nil }
        return ActivityRecoverySummary(
            unresolvedRunCount: projection.recoveryRunIDs.count,
            latestRecoveryRunID: projection.recoveryRunIDs.first
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
}
