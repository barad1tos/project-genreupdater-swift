import DesignUI
import Services

enum RunHistoryAdapter {
    static let runHistoryLimit = 50

    static func makeRunHistory(from projection: ReportsProjection) -> [RunReportRow] {
        projection.runs.map { run in
            RunReportRow(
                id: run.id,
                stateLabel: run.stateLabel,
                tone: makeTone(from: run.state),
                triggerLabel: run.triggerLabel,
                startedLabel: run.startedLabel,
                durationLabel: run.durationLabel,
                changeCountLabel: run.changeCountLabel,
                failureSummary: run.failureSummary
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
