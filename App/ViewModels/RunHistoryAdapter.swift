import DesignUI
import Foundation
import Services

enum RunHistoryAdapter {
    static let runHistoryLimit = 50

    static func makeInput(
        from page: RunReportPage,
        now: Date,
        activeRunID: RunID?
    ) -> ReportsProjectionInput {
        ReportsProjectionInput(
            records: page.records,
            skippedCorruptedCount: page.skippedCorruptedCount,
            recoveryRunIDs: page.unresolvedRunIDs,
            now: now,
            activeRunID: activeRunID
        )
    }

    static func makeRunHistory(from projection: ReportsProjection) -> [RunReportRow] {
        projection.runs.map { run in
            RunReportRow(
                id: run.id,
                stateLabel: run.stateLabel,
                tone: makeTone(from: run.state),
                triggerLabel: run.triggerLabel,
                startedLabel: run.startedLabel,
                modeLabel: run.modeLabel,
                scopeLabel: run.scopeLabel,
                durationLabel: run.durationLabel,
                changeCountLabel: run.changeCountLabel,
                failureSummary: run.failureSummary,
                lineageLabel: run.lineageLabel
            )
        }
    }

    static func makeTone(from state: ReportsRunState) -> Tone {
        switch state {
        case .running:
            .info
        case .awaitingReview:
            .warning
        case .completed:
            .success
        case .completedNoOp:
            .neutral
        case .blocked:
            .warning
        case .failed:
            .error
        case .cancelled:
            .neutral
        case .recoveryNeeded:
            .warning
        }
    }
}

/// Backend-owned reports assembly (ADR 0013): one publish path for the
/// host and every window-independent caller, with the active run read
/// from the orchestrator — never from view state.
extension AppDependencies {
    @discardableResult
    func refreshReportsProjection() async -> ReportsProjection? {
        let inputGeneration = await projectionStore.nextReportsProjectionInputGeneration()
        guard let page = await loadRunReportPage(limit: RunHistoryAdapter.runHistoryLimit) else { return nil }
        let lifecycle = await currentRunLifecycle()
        let activeRunID = lifecycle?.isActive == true ? lifecycle?.runID : nil
        let projection = ReportsBuilder.makeProjection(from: RunHistoryAdapter.makeInput(
            from: page,
            now: Date(),
            activeRunID: activeRunID
        ))
        return await projectionStore.replaceReportsProjection(projection, inputGeneration: inputGeneration)
    }
}
