import Foundation

public enum PipelineStage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case watch
    case detect
    case diff
    case fix
    case verify
    case report

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .watch: "Watch"
        case .detect: "Detect"
        case .diff: "Diff"
        case .fix: "Fix"
        case .verify: "Verify"
        case .report: "Report"
        }
    }

    public var detail: String {
        switch self {
        case .watch: "background"
        case .detect: "changes"
        case .diff: "current"
        case .fix: "gated"
        case .verify: "after write"
        case .report: "audit trail"
        }
    }

    public var symbol: String {
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

public enum PipelineStageStatus: Equatable, Sendable {
    case completed
    case current
    case gated
    case pending
    case failed
}

public enum PipelineSafetyMode: Equatable, Sendable {
    case preview
    case autoFix

    public var title: String {
        switch self {
        case .preview: "Preview"
        case .autoFix: "Auto-fix"
        }
    }
}

public enum PipelineActionStyle: Equatable, Sendable {
    case primary
    case secondary
}

public struct PipelineAction: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let style: PipelineActionStyle

    public init(title: String, symbol: String, style: PipelineActionStyle) {
        self.title = title
        self.symbol = symbol
        self.style = style
    }
}

public struct PipelineActivitySnapshot: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let currentStage: PipelineStage
    public let safetyMode: PipelineSafetyMode
    public let deltaCount: Int
    public let interventionCount: Int
    public let protectedCount: Int
    public let failedWriteCount: Int
    public let isUndoReady: Bool
    public let primaryAction: PipelineAction
    public let secondaryAction: PipelineAction?
    private let stageStatuses: [PipelineStage: PipelineStageStatus]

    public init(
        title: String,
        subtitle: String,
        currentStage: PipelineStage,
        safetyMode: PipelineSafetyMode,
        deltaCount: Int,
        interventionCount: Int,
        protectedCount: Int,
        failedWriteCount: Int,
        isUndoReady: Bool,
        primaryAction: PipelineAction,
        secondaryAction: PipelineAction?,
        stageStatuses: [PipelineStage: PipelineStageStatus]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.currentStage = currentStage
        self.safetyMode = safetyMode
        self.deltaCount = deltaCount
        self.interventionCount = interventionCount
        self.protectedCount = protectedCount
        self.failedWriteCount = failedWriteCount
        self.isUndoReady = isUndoReady
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.stageStatuses = stageStatuses
    }

    public func status(for stage: PipelineStage) -> PipelineStageStatus {
        stageStatuses[stage] ?? .pending
    }

    public static func previewDefault(
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
