import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("WorkflowDashboardState adapter")
@MainActor
struct WorkflowDashboardStateTests {
    @Test("configure phase exposes empty dashboard state")
    func configurePhaseExposesEmptyDashboardState() {
        let viewModel = makeWorkflowViewModel()

        #expect(viewModel.dashboardState == .empty)
    }

    @Test("review phase exposes proposed and accepted counts")
    func reviewPhaseExposesProposedAndAcceptedCounts() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .review
        viewModel.proposedChanges = [
            makeProposedChange(id: "1", isAccepted: true),
            makeProposedChange(id: "2", isAccepted: false),
            makeProposedChange(id: "3", isAccepted: true),
        ]
        viewModel.failedCount = 1

        let state = viewModel.dashboardState

        #expect(state.proposedChangeCount == 3)
        #expect(state.acceptedChangeCount == 2)
        #expect(state.failedWriteCount == 1)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "review")
    }

    @Test("scanning and applying phases are processing with phase labels")
    func scanningAndApplyingPhasesAreProcessingWithPhaseLabels() {
        let viewModel = makeWorkflowViewModel()
        viewModel.proposedChanges = [
            makeProposedChange(id: "1", isAccepted: true),
            makeProposedChange(id: "2", isAccepted: true),
        ]

        viewModel.phase = .scanning
        let scanningState = viewModel.dashboardState

        #expect(scanningState.proposedChangeCount == 2)
        #expect(scanningState.acceptedChangeCount == 2)
        #expect(scanningState.isProcessing)
        #expect(scanningState.phaseLabel == "scanning")

        viewModel.phase = .applying
        let applyingState = viewModel.dashboardState

        #expect(applyingState.proposedChangeCount == 2)
        #expect(applyingState.acceptedChangeCount == 2)
        #expect(applyingState.isProcessing)
        #expect(applyingState.phaseLabel == "applying")
    }

    @Test("error phase uses failed track statuses when they exceed failed count")
    func errorPhaseUsesFailedTrackStatusesWhenTheyExceedFailedCount() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .error("Write failed")
        viewModel.failedCount = 1
        viewModel.trackStatuses = [
            "1": .failed("AppleScript failed"),
            "2": .failed("Missing track"),
            "3": .done,
        ]

        let state = viewModel.dashboardState

        #expect(state.failedWriteCount == 2)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "error")
    }

    @Test("done phase clears accepted dashboard count")
    func donePhaseClearsAcceptedDashboardCount() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .done
        viewModel.proposedChanges = [
            makeProposedChange(id: "1", isAccepted: true),
            makeProposedChange(id: "2", isAccepted: true),
        ]

        let state = viewModel.dashboardState

        #expect(state.proposedChangeCount == 2)
        #expect(state.acceptedChangeCount == 0)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "done")
    }

    @Test("done phase preserves failed writes from batch result")
    func donePhasePreservesFailedWritesFromBatchResult() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .done
        viewModel.result = BatchUpdateResult(
            entries: [],
            failedTrackIDs: ["1", "2"],
            errorDescriptions: ["First failed", "Second failed"]
        )

        let state = viewModel.dashboardState

        #expect(state.failedWriteCount == 2)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "done")
    }

    @Test("failed count wins when it exceeds failed track statuses")
    func failedCountWinsWhenItExceedsFailedTrackStatuses() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .review
        viewModel.failedCount = 3
        viewModel.trackStatuses = [
            "1": .failed("AppleScript failed"),
            "2": .done,
        ]

        let state = viewModel.dashboardState

        #expect(state.failedWriteCount == 3)
        #expect(!state.isProcessing)
        #expect(state.phaseLabel == "review")
    }
}
