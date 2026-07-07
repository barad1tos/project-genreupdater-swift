import DesignUI
import Services

enum ReportsProjectionDesignAdapter {
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
        case .completed:
            .success
        case .completedNoOp:
            .neutral
        case .failed:
            .error
        case .recoveryNeeded:
            .warning
        }
    }
}
