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
        #expect(snapshot.status(for: .watch) == .completed)
        #expect(snapshot.status(for: .detect) == .completed)
        #expect(snapshot.status(for: .diff) == .current)
        #expect(snapshot.status(for: .fix) == .gated)
        #expect(snapshot.status(for: .verify) == .pending)
        #expect(snapshot.status(for: .report) == .pending)
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
}
