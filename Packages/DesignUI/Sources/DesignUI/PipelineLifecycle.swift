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

    var defaultDetail: String {
        switch self {
        case .watch: "Manual scan only"
        case .detect: "Changes"
        case .diff: "Current"
        case .fix: "Gated"
        case .verify: "After write"
        case .report: "Audit trail"
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

public enum PipelineAutomationState: Equatable, Sendable {
    case autoSyncRunning
    case manualScanOnly
    case noSyncYet

    public var summaryValue: String {
        switch self {
        case .autoSyncRunning:
            return "Running"
        case .manualScanOnly:
            return "Manual"
        case .noSyncYet:
            return "Idle"
        }
    }

    public var stageDetail: String {
        switch self {
        case .autoSyncRunning:
            return "Auto-sync running"
        case .manualScanOnly:
            return "Manual scan only"
        case .noSyncYet:
            return "No sync yet"
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
    public let isEnabled: Bool

    public init(title: String, symbol: String, style: PipelineActionStyle, isEnabled: Bool = true) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.isEnabled = isEnabled
    }
}

public struct PipelineStageDescriptor: Identifiable, Equatable, Sendable {
    public var id: PipelineStage { stage }

    public let stage: PipelineStage
    public let detail: String
    public let status: PipelineStageStatus

    public init(stage: PipelineStage, detail: String, status: PipelineStageStatus) {
        self.stage = stage
        self.detail = detail
        self.status = status
    }
}

public struct PipelineActivitySnapshot: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let currentStage: PipelineStage
    public let safetyMode: PipelineSafetyMode
    public let automationState: PipelineAutomationState
    public let deltaCount: Int
    public let interventionCount: Int
    public let protectedCount: Int
    public let failedWriteCount: Int
    public let isUndoReady: Bool
    public let primaryAction: PipelineAction
    public let secondaryAction: PipelineAction?
    public let stageDescriptors: [PipelineStageDescriptor]
    private let stageStatuses: [PipelineStage: PipelineStageStatus]

    /// Stage descriptors are authoritative for visible stage copy and status.
    /// `stageStatuses` fills any descriptor omitted by older call sites.
    public init(
        title: String,
        subtitle: String,
        currentStage: PipelineStage,
        safetyMode: PipelineSafetyMode,
        automationState: PipelineAutomationState = .manualScanOnly,
        deltaCount: Int,
        interventionCount: Int,
        protectedCount: Int,
        failedWriteCount: Int,
        isUndoReady: Bool,
        primaryAction: PipelineAction,
        secondaryAction: PipelineAction?,
        stageStatuses: [PipelineStage: PipelineStageStatus],
        stageDescriptors: [PipelineStageDescriptor]? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.currentStage = currentStage
        self.safetyMode = safetyMode
        self.automationState = automationState
        self.deltaCount = deltaCount
        self.interventionCount = interventionCount
        self.protectedCount = protectedCount
        self.failedWriteCount = failedWriteCount
        self.isUndoReady = isUndoReady
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.stageDescriptors = Self.normalizedStageDescriptors(
            stageDescriptors,
            stageStatuses: stageStatuses
        )
        self.stageStatuses = Dictionary(uniqueKeysWithValues: self.stageDescriptors.map { ($0.stage, $0.status) })
    }

    public func status(for stage: PipelineStage) -> PipelineStageStatus {
        stageStatuses[stage] ?? .pending
    }

    public func detail(for stage: PipelineStage) -> String {
        stageDescriptors.first { $0.stage == stage }?.detail ?? stage.defaultDetail
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
            automationState: .manualScanOnly,
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
            ],
            stageDescriptors: [
                PipelineStageDescriptor(stage: .watch, detail: "Manual scan only", status: .completed),
                PipelineStageDescriptor(stage: .detect, detail: "Polling enabled", status: .completed),
                PipelineStageDescriptor(stage: .diff, detail: "Current delta", status: .current),
                PipelineStageDescriptor(stage: .fix, detail: "Preview gated", status: .gated),
                PipelineStageDescriptor(stage: .verify, detail: "After write", status: .pending),
                PipelineStageDescriptor(stage: .report, detail: "Audit trail", status: .pending),
            ]
        )
    }

    private static func normalizedStageDescriptors(
        _ descriptors: [PipelineStageDescriptor]?,
        stageStatuses: [PipelineStage: PipelineStageStatus]
    ) -> [PipelineStageDescriptor] {
        PipelineStage.allCases.map { stage in
            if let descriptor = descriptors?.first(where: { $0.stage == stage }) {
                return descriptor
            }

            return PipelineStageDescriptor(
                stage: stage,
                detail: stage.defaultDetail,
                status: stageStatuses[stage] ?? .pending
            )
        }
    }
}
