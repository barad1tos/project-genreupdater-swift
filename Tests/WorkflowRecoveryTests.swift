import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("Workflow recovery")
@MainActor
struct WorkflowRecoveryTests {
    @Test("Unknown write blocks alternate scopes until recovery clearance")
    func unknownWriteBlocks() async {
        let fixture = makeWorkflowFixture(outcomeWriteTrackIDs: ["unknown"])
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "unknown", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        let recoveryID = viewModel.recoveryHoldID
        #expect(recoveryID != nil)
        #expect(!viewModel.canStart)

        viewModel.configureSelectedTracksScope(
            tracks: [Track(id: "safe", name: "Safe", artist: "Artist", album: "Album")],
            updateGenre: true,
            updateYear: false,
            previewOnly: false
        )
        viewModel.phase = .review
        viewModel.proposedChanges = [makeProposedChange(id: "safe", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)

        await viewModel.clearRecoveryHold()
        #expect(viewModel.recoveryHoldID == nil)
        #expect(viewModel.canStart)
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "safe", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(await fixture.scriptClient.updatedProperties().map(\.trackID) == ["safe"])
    }

    @Test("Fallback marker blocks a restarted workflow")
    func fallbackMarkerBlocksRestart() async throws {
        let checkpointRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Workflow-invalid-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: checkpointRoot)
        defer { try? FileManager.default.removeItem(at: checkpointRoot) }
        let suiteName = "WorkflowRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFixture = makeWorkflowFixture(
            checkpointDirectory: checkpointRoot,
            recoverySuiteName: suiteName
        )
        let recoveryID = await firstFixture.batchProcessor.beginRecoveryHold()
        let restarted = makeWorkflowFixture(
            checkpointDirectory: checkpointRoot,
            recoverySuiteName: suiteName
        )
        let viewModel = restarted.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "safe", isAccepted: true)]
        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        #expect(viewModel.recoveryHoldID == recoveryID)
        #expect(!viewModel.canStart)
        #expect(await restarted.scriptClient.updatedProperties().isEmpty)

        try FileManager.default.removeItem(at: checkpointRoot)
        try FileManager.default.createDirectory(at: checkpointRoot, withIntermediateDirectories: true)
        await viewModel.clearRecoveryHold()
        #expect(viewModel.recoveryHoldID == nil)
        #expect(await restarted.batchProcessor.recoveryHoldID() == nil)
    }
}
