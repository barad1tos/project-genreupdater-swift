// WorkflowViewModel+DashboardState.swift -- Dashboard adapter for workflow progress.

extension WorkflowViewModel {
    var dashboardState: WorkflowDashboardState {
        switch phase {
        case .configure:
            .empty
        case .scanning:
            WorkflowDashboardState(
                proposedChangeCount: proposedChanges.count,
                acceptedChangeCount: acceptedCount,
                failedWriteCount: dashboardFailedWriteCount,
                isProcessing: true,
                phaseLabel: "scanning"
            )
        case .review:
            WorkflowDashboardState(
                proposedChangeCount: proposedChanges.count,
                acceptedChangeCount: acceptedCount,
                failedWriteCount: dashboardFailedWriteCount,
                isProcessing: false,
                phaseLabel: "review"
            )
        case .applying:
            WorkflowDashboardState(
                proposedChangeCount: proposedChanges.count,
                acceptedChangeCount: acceptedCount,
                failedWriteCount: dashboardFailedWriteCount,
                isProcessing: true,
                phaseLabel: "applying"
            )
        case .done:
            WorkflowDashboardState(
                proposedChangeCount: proposedChanges.count,
                acceptedChangeCount: 0,
                failedWriteCount: dashboardFailedWriteCount,
                isProcessing: false,
                phaseLabel: "done"
            )
        case .paused:
            WorkflowDashboardState(
                proposedChangeCount: proposedChanges.count,
                acceptedChangeCount: acceptedCount,
                failedWriteCount: dashboardFailedWriteCount,
                isProcessing: false,
                phaseLabel: "paused"
            )
        case .error:
            WorkflowDashboardState(
                proposedChangeCount: proposedChanges.count,
                acceptedChangeCount: acceptedCount,
                failedWriteCount: dashboardFailedWriteCount,
                isProcessing: false,
                phaseLabel: "error"
            )
        }
    }

    private var dashboardFailedWriteCount: Int {
        max(failedCount, result?.failedTrackIDs.count ?? 0, failedTracks.count)
    }
}
