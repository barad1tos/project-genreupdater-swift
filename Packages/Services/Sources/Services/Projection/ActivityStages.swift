extension ActivityBuilder {
    static func makeCurrentStage(input: ActivityProjectionInput) -> ActivityPipelineStage {
        if let libraryStage = makeLibraryCurrentStage(input: input) {
            return libraryStage
        }

        if input.hasRecovery {
            return .fix
        }

        if let syncStage = input.effectiveSyncState.activeStage {
            return syncStage
        }
        if input.workflow.isProcessing || input.acceptedFixCount > 0 {
            return .fix
        }
        if input.proposedFixCount > 0 {
            return .diff
        }
        if case .completed = input.effectiveSyncState {
            return .diff
        }
        return input.isAutoSyncRunning ? .watch : .detect
    }

    static func makeLibraryCurrentStage(input: ActivityProjectionInput) -> ActivityPipelineStage? {
        switch input.libraryState {
        case .loading, .permissionDenied, .failed:
            .detect
        case .empty:
            input.effectiveSyncState == .idle ? .watch : nil
        case .ready:
            nil
        }
    }

    static func makeStageDescriptors(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage,
        syncSummary: ActivitySyncSummary?
    ) -> [ActivityPipelineStageDescriptor] {
        [
            ActivityPipelineStageDescriptor(
                stage: .watch,
                detail: makeAutomationState(input: input) == .autoSyncRunning ? "Auto-sync running" :
                    "Manual scan only",
                status: watchStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .detect,
                detail: detectDetail(input: input),
                status: detectStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .diff,
                detail: syncSummary?.resultDetail ?? "No delta",
                status: diffStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .fix,
                detail: input.processingMode == .preview ? "Preview gated" : "Write mode",
                status: fixStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .verify,
                detail: input.pendingVerification == nil ? "Not available" : "Pending summary",
                status: .pending
            ),
            ActivityPipelineStageDescriptor(stage: .report, detail: "Audit trail", status: .pending)
        ]
    }

    static func watchStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        if currentStage == .watch {
            return .current
        }

        switch input.libraryState {
        case .permissionDenied, .failed:
            return .failed
        case .loading, .empty, .ready:
            return .completed
        }
    }

    static func detectDetail(input: ActivityProjectionInput) -> String {
        input.effectiveSyncState.detectDetail
            ?? (input.isAutoSyncRunning ? "Periodic polling" : "Manual trigger")
    }

    static func detectStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        switch input.effectiveSyncState {
        case .running:
            return .current
        case .failed:
            return .failed
        case .awaitingReview, .blocked, .recoveryNeeded:
            return .completed
        case .cancelled, .completed:
            return currentStage == .detect ? .current : .completed
        case .idle:
            break
        }

        switch input.libraryState {
        case .loading:
            return .current
        case .permissionDenied, .failed:
            return .failed
        case .empty:
            return .pending
        case .ready:
            return currentStage == .detect ? .current : .completed
        }
    }

    static func diffStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        if input.proposedFixCount > 0 {
            return currentStage == .diff ? .current : .completed
        }
        if case .awaitingReview = input.effectiveSyncState {
            return currentStage == .diff ? .current : .pending
        }
        if case .completed = input.effectiveSyncState {
            return currentStage == .diff ? .current : .completed
        }
        return .pending
    }

    static func fixStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        if input.hasRecovery {
            return .gated
        }
        if input.effectiveSyncState.requiresRecoveryAttention {
            return .gated
        }
        if input.workflow.failedWriteCount > 0 {
            return .failed
        }
        if input.workflow.isProcessing {
            return currentStage == .fix ? .current : .pending
        }
        if input.proposedFixCount > 0 || input.acceptedFixCount > 0 {
            return input.processingMode == .preview ? .gated : .pending
        }
        return .pending
    }
}
