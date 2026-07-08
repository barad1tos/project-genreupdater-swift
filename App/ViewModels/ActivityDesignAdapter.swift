import DesignUI
import Services

enum ActivityDesignAdapter {
    static func makePipelineSnapshot(
        from projection: ActivityProjection,
        notice: String? = nil
    ) -> PipelineActivitySnapshot {
        let stageStatuses = Dictionary(uniqueKeysWithValues: ActivityPipelineStage.allCases.map { stage in
            (makeStage(from: stage), makeStatus(from: projection.status(for: stage)))
        })

        return PipelineActivitySnapshot(
            title: projection.title,
            subtitle: notice ?? projection.subtitle,
            currentStage: makeStage(from: projection.currentStage),
            safetyMode: makeSafetyMode(from: projection.processingMode),
            automationState: makeAutomationState(from: projection.automationState),
            deltaCount: projection.deltaCount,
            deltaDetail: makeDeltaDetail(from: projection),
            interventionCount: projection.interventionCount,
            protectedCount: projection.protectedCount,
            failedWriteCount: projection.failedWriteCount,
            isUndoReady: projection.isUndoReady,
            primaryAction: makePrimaryAction(from: projection.primaryCommand),
            secondaryAction: projection.secondaryCommand.map(makeAction),
            stageStatuses: stageStatuses,
            stageDescriptors: projection.stageDescriptors.map(makeStageDescriptor)
        )
    }

    static func makeActivityItems(from projection: ActivityProjection) -> [ActivityItem] {
        projection.recentActivity.map { item in
            ActivityItem(id: item.id, title: item.title, detail: item.detail)
        }
    }

    private static func makeDeltaDetail(from projection: ActivityProjection) -> String {
        projection.summaryCards.first { $0.kind == .delta }?.detail ?? "candidate fixes"
    }

    private static func makePrimaryAction(from command: ActivityCommandDescriptor?) -> PipelineAction {
        guard let command else {
            return PipelineAction(
                title: "Review changes",
                symbol: "checklist",
                style: .primary,
                isEnabled: false
            )
        }

        return makeAction(from: command)
    }

    private static func makeAction(from command: ActivityCommandDescriptor) -> PipelineAction {
        PipelineAction(
            title: command.title,
            symbol: makeSymbol(for: command),
            style: makeActionStyle(from: command.style),
            isEnabled: command.isEnabled
        )
    }

    private static func makeStageDescriptor(
        from descriptor: ActivityPipelineStageDescriptor
    ) -> PipelineStageDescriptor {
        PipelineStageDescriptor(
            stage: makeStage(from: descriptor.stage),
            detail: descriptor.detail,
            status: makeStatus(from: descriptor.status)
        )
    }

    private static func makeStage(from stage: ActivityPipelineStage) -> PipelineStage {
        switch stage {
        case .watch:
            .watch
        case .detect:
            .detect
        case .diff:
            .diff
        case .fix:
            .fix
        case .verify:
            .verify
        case .report:
            .report
        }
    }

    private static func makeStatus(from status: ActivityPipelineStageStatus) -> PipelineStageStatus {
        switch status {
        case .completed:
            .completed
        case .current:
            .current
        case .gated:
            .gated
        case .pending:
            .pending
        case .failed:
            .failed
        }
    }

    private static func makeSafetyMode(from mode: ActivityProcessingMode) -> PipelineSafetyMode {
        switch mode {
        case .preview:
            .preview
        case .autoFix:
            .autoFix
        }
    }

    private static func makeAutomationState(from state: ActivityAutomationState) -> PipelineAutomationState {
        switch state {
        case .autoSyncRunning:
            .autoSyncRunning
        case .manualScanOnly:
            .manualScanOnly
        case .noSyncYet:
            .noSyncYet
        }
    }

    private static func makeActionStyle(from style: ActivityCommandStyle) -> PipelineActionStyle {
        switch style {
        case .primary:
            .primary
        case .secondary:
            .secondary
        }
    }

    private static func makeSymbol(for command: ActivityCommandDescriptor) -> String {
        switch command.commandKind {
        case .acceptFixPlan:
            "checkmark.circle"
        case .rejectFixPlan:
            "xmark.circle"
        case .reviewChanges:
            "checklist"
        case .resumeRecovery:
            "shield.checkerboard"
        case .togglePlanItem:
            "arrow.triangle.2.circlepath"
        case .runManually:
            switch command.variant {
            case .standard:
                "arrow.clockwise"
            case .libraryCheck:
                "magnifyingglass"
            }
        }
    }
}
