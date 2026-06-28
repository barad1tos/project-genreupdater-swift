import Testing
@testable import DesignUI

@Suite("Pipeline lifecycle")
struct PipelineLifecycleTests {
    @Test
    func previewSnapshotStopsAtDiffAndGatesFix() {
        let snapshot = PipelineActivitySnapshot.previewDefault(
            deltaCount: 211,
            interventionCount: 142,
            protectedCount: 18,
            failedWriteCount: 0
        )

        #expect(snapshot.currentStage == .diff)
        #expect(snapshot.safetyMode == .preview)
        #expect(snapshot.automationState == .manualScanOnly)
        #expect(snapshot.status(for: .watch) == .completed)
        #expect(snapshot.status(for: .detect) == .completed)
        #expect(snapshot.status(for: .diff) == .current)
        #expect(snapshot.status(for: .fix) == .gated)
        #expect(snapshot.status(for: .verify) == .pending)
        #expect(snapshot.status(for: .report) == .pending)
        #expect(snapshot.stageDescriptors.map(\.stage) == PipelineStage.allCases)
        #expect(snapshot.detail(for: .watch) == "Manual scan only")
    }

    @Test
    func previewSnapshotUsesReviewFixPlanAsPrimaryAction() {
        let snapshot = PipelineActivitySnapshot.previewDefault(
            deltaCount: 211,
            interventionCount: 142,
            protectedCount: 18,
            failedWriteCount: 0
        )

        #expect(snapshot.title == "Fix plan ready")
        #expect(snapshot.primaryAction.title == "Review fix plan")
        #expect(snapshot.primaryAction.symbol == "checklist")
        #expect(snapshot.primaryAction.style == .primary)
        #expect(snapshot.secondaryAction?.title == "Run manually")
    }

    @Test
    func lifecycleStagesUseTechnicalOrder() {
        #expect(PipelineStage.allCases.map(\.title) == [
            "Watch",
            "Detect",
            "Diff",
            "Fix",
            "Verify",
            "Report",
        ])
    }

    @Test
    func lifecycleUsesSnapshotProvidedStageCopy() {
        let snapshot = PipelineActivitySnapshot(
            title: "Pipeline",
            subtitle: "No sync yet",
            currentStage: .watch,
            safetyMode: .preview,
            automationState: .noSyncYet,
            deltaCount: 0,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryAction: PipelineAction(title: "Run manually", symbol: "arrow.clockwise", style: .primary),
            secondaryAction: nil,
            stageStatuses: [.watch: .current],
            stageDescriptors: [
                PipelineStageDescriptor(stage: .watch, detail: "No sync yet", status: .current),
            ]
        )

        #expect(snapshot.detail(for: .watch) == "No sync yet")
        #expect(snapshot.status(for: .watch) == .current)
        #expect(snapshot.stageDescriptors.first?.status == .current)
        #expect(!snapshot.stageDescriptors.contains { $0.detail.contains("FSEvents") })
    }
}
