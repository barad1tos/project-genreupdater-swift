import Foundation

public enum ActivityPipelineStage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case watch
    case detect
    case diff
    case fix
    case verify
    case report

    public var id: String {
        rawValue
    }
}

public enum ActivityPipelineStageStatus: String, Equatable, Sendable {
    case completed
    case current
    case gated
    case pending
    case failed
}

public enum ActivityProcessingMode: String, Equatable, Sendable {
    case preview
    case autoFix
}

public enum ActivityAutomationState: String, Equatable, Sendable {
    case autoSyncRunning
    case manualScanOnly
    case noSyncYet
}

public enum ActivityCommandStyle: String, Equatable, Sendable {
    case primary
    case secondary
}

public struct ActivityCommandDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let style: ActivityCommandStyle
    public let isEnabled: Bool
    public let commandKind: UserIntentCommandKind

    public init(
        id: String,
        title: String,
        style: ActivityCommandStyle,
        isEnabled: Bool,
        commandKind: UserIntentCommandKind
    ) {
        self.id = id
        self.title = title
        self.style = style
        self.isEnabled = isEnabled
        self.commandKind = commandKind
    }
}

public struct ActivityPipelineStageDescriptor: Identifiable, Equatable, Sendable {
    public let stage: ActivityPipelineStage
    public let detail: String
    public let status: ActivityPipelineStageStatus

    public var id: ActivityPipelineStage {
        stage
    }

    public init(
        stage: ActivityPipelineStage,
        detail: String,
        status: ActivityPipelineStageStatus
    ) {
        self.stage = stage
        self.detail = detail
        self.status = status
    }
}

public struct ActivityRecentItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public enum ActivitySummaryCardKind: String, Equatable, Sendable {
    case automation
    case delta
    case quality
}

public struct ActivitySummaryCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: ActivitySummaryCardKind
    public let label: String
    public let value: String
    public let detail: String

    public init(id: String, kind: ActivitySummaryCardKind, label: String, value: String, detail: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.detail = detail
    }
}

public struct ActivityProjection: Equatable, Sendable {
    public let revision: ProjectionRevision
    public let title: String
    public let subtitle: String
    public let syncStatusText: String
    public let currentStage: ActivityPipelineStage
    public let processingMode: ActivityProcessingMode
    public let automationState: ActivityAutomationState
    public let deltaCount: Int
    public let interventionCount: Int
    public let protectedCount: Int
    public let failedWriteCount: Int
    public let isUndoReady: Bool
    public let primaryCommand: ActivityCommandDescriptor?
    public let secondaryCommand: ActivityCommandDescriptor?
    public let stageDescriptors: [ActivityPipelineStageDescriptor]
    public let recentActivity: [ActivityRecentItem]
    public let summaryCards: [ActivitySummaryCard]
    public let operationalIssues: [OperationalIssue]

    public init(
        revision: ProjectionRevision,
        title: String,
        subtitle: String,
        syncStatusText: String,
        currentStage: ActivityPipelineStage,
        processingMode: ActivityProcessingMode,
        automationState: ActivityAutomationState,
        deltaCount: Int,
        interventionCount: Int,
        protectedCount: Int,
        failedWriteCount: Int,
        isUndoReady: Bool,
        primaryCommand: ActivityCommandDescriptor?,
        secondaryCommand: ActivityCommandDescriptor?,
        stageDescriptors: [ActivityPipelineStageDescriptor],
        recentActivity: [ActivityRecentItem],
        summaryCards: [ActivitySummaryCard],
        operationalIssues: [OperationalIssue]
    ) {
        self.revision = revision
        self.title = title
        self.subtitle = subtitle
        self.syncStatusText = syncStatusText
        self.currentStage = currentStage
        self.processingMode = processingMode
        self.automationState = automationState
        self.deltaCount = deltaCount
        self.interventionCount = interventionCount
        self.protectedCount = protectedCount
        self.failedWriteCount = failedWriteCount
        self.isUndoReady = isUndoReady
        self.primaryCommand = primaryCommand
        self.secondaryCommand = secondaryCommand
        self.stageDescriptors = stageDescriptors
        self.recentActivity = recentActivity
        self.summaryCards = summaryCards
        self.operationalIssues = operationalIssues
    }

    public func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            title: title,
            subtitle: subtitle,
            syncStatusText: syncStatusText,
            currentStage: currentStage,
            processingMode: processingMode,
            automationState: automationState,
            deltaCount: deltaCount,
            interventionCount: interventionCount,
            protectedCount: protectedCount,
            failedWriteCount: failedWriteCount,
            isUndoReady: isUndoReady,
            primaryCommand: primaryCommand,
            secondaryCommand: secondaryCommand,
            stageDescriptors: stageDescriptors,
            recentActivity: recentActivity,
            summaryCards: summaryCards,
            operationalIssues: operationalIssues
        )
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            title: "Activity",
            subtitle: "No sync yet",
            syncStatusText: "No sync yet",
            currentStage: .watch,
            processingMode: .preview,
            automationState: .noSyncYet,
            deltaCount: 0,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: nil,
            secondaryCommand: ActivityCommandDescriptor(
                id: "run-manually",
                title: "Run manually",
                style: .secondary,
                isEnabled: false,
                commandKind: .runManually
            ),
            stageDescriptors: ActivityPipelineStage.allCases.map {
                ActivityPipelineStageDescriptor(stage: $0, detail: "Not available", status: .pending)
            },
            recentActivity: [],
            summaryCards: [],
            operationalIssues: []
        )
    }

    public func status(for stage: ActivityPipelineStage) -> ActivityPipelineStageStatus {
        stageDescriptors.first { $0.stage == stage }?.status ?? .pending
    }
}
