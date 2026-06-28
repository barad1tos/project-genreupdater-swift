import Foundation

enum PipelineStage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case watch
    case detect
    case diff
    case fix
    case verify
    case report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watch: "Watch"
        case .detect: "Detect"
        case .diff: "Diff"
        case .fix: "Fix"
        case .verify: "Verify"
        case .report: "Report"
        }
    }

    var detail: String {
        switch self {
        case .watch: "background"
        case .detect: "changes"
        case .diff: "current"
        case .fix: "gated"
        case .verify: "after write"
        case .report: "audit trail"
        }
    }

    var symbol: String {
        switch self {
        case .watch: "waveform.path.ecg"
        case .detect: "dot.radiowaves.left.and.right"
        case .diff: "arrow.triangle.2.circlepath"
        case .fix: "wand.and.stars"
        case .verify: "checkmark.seal"
        case .report: "doc.text.magnifyingglass"
        }
    }
}

enum PipelineStageStatus: Equatable, Sendable {
    case completed
    case current
    case gated
    case pending
    case failed
}

enum PipelineSafetyMode: Equatable, Sendable {
    case preview
    case autoFix

    var title: String {
        switch self {
        case .preview: "Preview"
        case .autoFix: "Auto-fix"
        }
    }
}

enum PipelineActionStyle: Equatable, Sendable {
    case primary
    case secondary
}

struct PipelineAction: Equatable, Sendable {
    let title: String
    let symbol: String
    let style: PipelineActionStyle
}

struct PipelineActivitySnapshot: Equatable, Sendable {
    let title: String
    let subtitle: String
    let currentStage: PipelineStage
    let safetyMode: PipelineSafetyMode
    let deltaCount: Int
    let interventionCount: Int
    let protectedCount: Int
    let failedWriteCount: Int
    let isUndoReady: Bool
    let primaryAction: PipelineAction
    let secondaryAction: PipelineAction?
    private let stageStatuses: [PipelineStage: PipelineStageStatus]

    func status(for stage: PipelineStage) -> PipelineStageStatus {
        stageStatuses[stage] ?? .pending
    }

    static func previewDefault(
        deltaCount: Int,
        interventionCount: Int,
        protectedCount: Int,
        failedWriteCount: Int
    ) -> Self {
        Self(
            title: "Fix plan ready",
            subtitle: "Automatic diff completed · preview mode · no Music tags written",
            currentStage: .diff,
            safetyMode: .preview,
            deltaCount: deltaCount,
            interventionCount: interventionCount,
            protectedCount: protectedCount,
            failedWriteCount: failedWriteCount,
            isUndoReady: true,
            primaryAction: PipelineAction(
                title: "Review fix plan",
                symbol: "checklist",
                style: .primary
            ),
            secondaryAction: PipelineAction(
                title: "Run manually",
                symbol: "arrow.clockwise",
                style: .secondary
            ),
            stageStatuses: [
                .watch: .completed,
                .detect: .completed,
                .diff: .current,
                .fix: .gated,
                .verify: .pending,
                .report: .pending,
            ]
        )
    }
}
