import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow mutation preparation")
@MainActor
struct MutationMetadataTests {
    @Test("preview skips mutation metadata before dry-run")
    func previewSkipsMutationMetadataBeforeDryRun() async throws {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        let tracks = [
            Track(id: "selected-1", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
        ]
        viewModel.configureSelectedTracksScope(
            tracks: tracks,
            updateGenre: true,
            updateYear: false,
            previewOnly: true
        )

        viewModel.start(tracks: tracks)
        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await recorder.recordedCallCount() == 0)
        #expect(await recorder.preparedTrackIDs.isEmpty)
    }

    @Test("preview continues while recovery hold is active")
    func previewContinuesWhileRecoveryHoldIsActive() async throws {
        let fixture = makeWorkflowFixture(
            hasRecoveryHold: { true }
        )
        let viewModel = fixture.viewModel
        let tracks = [
            Track(id: "selected-1", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
        ]
        viewModel.configureSelectedTracksScope(
            tracks: tracks,
            updateGenre: true,
            updateYear: false,
            previewOnly: true
        )

        viewModel.start(tracks: tracks)
        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .review = viewModel.phase else {
            #expect(Bool(false), "preview should remain available during recovery hold")
            return
        }
    }

    @Test("apply accepted prepares mutation metadata before write")
    func applyAcceptedPreparesMutationMetadataBeforeWrite() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
            makeProposedChange(id: "rejected", isAccepted: false),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        #expect(await recorder.preparedTrackIDs == ["accepted"])
    }

    @Test("apply accepted stops when recovery hold is active")
    func applyAcceptedStopsWhenRecoveryHoldIsActive() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            hasRecoveryHold: { true },
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "recovery hold should stop the write workflow")
            return
        }
        #expect(message == "Previous run needs recovery before writes continue.")
        #expect(await recorder.recordedCallCount() == 0)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("apply accepted prepares each track once")
    func applyAcceptedPreparesEachTrackOnce() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        let track = Track(id: "accepted", name: "Track accepted", artist: "Artist", album: "Album")
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: nil,
                newValue: "Rock",
                confidence: 90,
                source: "test",
                isAccepted: true
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: nil,
                newValue: "1989",
                confidence: 90,
                source: "test",
                isAccepted: true
            ),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        #expect(await recorder.recordedCallCount() == 1)
        #expect(await recorder.preparedTrackIDs == ["accepted"])
    }

    @Test("preparation failure surfaces workflow error")
    func preparationFailureSurfacesWorkflowError() async {
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { _ in
                throw MutationPreparationError.failed
            }
        )
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "failed preparation should surface an error")
            return
        }
        #expect(message == "metadata preparation failed")
        #expect(viewModel.progress == nil)
    }

    @Test("missing preparation service blocks write workflow")
    func missingPreparationServiceBlocksWriteWorkflow() async {
        let viewModel = makeWorkflowFixture(prepareMutationMetadata: nil).viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "missing preparation service should surface an error")
            return
        }
        #expect(message == "Music write metadata service is unavailable")
        #expect(viewModel.progress == nil)
    }

    @Test("preparation cancellation returns to configuration")
    func preparationCancellationReturnsToConfiguration() async {
        let hold = MutationPreparationHold()
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { _ in
                await hold.hold()
                try Task.checkCancellation()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
        ]

        viewModel.applyAccepted()
        await hold.waitUntilStarted()
        let processingTask = viewModel.processingTask

        viewModel.cancel()
        await hold.release()
        await processingTask?.value
        await Task.yield()

        guard case .configure = viewModel.phase else {
            #expect(Bool(false), "cancelled preparation should return to configuration")
            return
        }
        #expect(viewModel.progress == nil)
    }

    @Test("full library preparation uses narrowed processing scope")
    func fullLibraryPreparationUsesNarrowedProcessingScope() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == "processable" }
            },
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
                throw CancellationError()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false
        let tracks = [
            Track(id: "processable", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
            Track(id: "filtered", name: "Orion", artist: "Metallica", album: "Master of Puppets"),
        ]

        viewModel.start(tracks: tracks)
        await viewModel.processingTask?.value
        await Task.yield()

        #expect(await recorder.preparedTrackIDs == ["processable"])
    }

    @Test("full library write stops when recovery hold is active")
    func fullLibraryWriteStopsWhenRecoveryHoldIsActive() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            hasRecoveryHold: { true },
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false

        viewModel.start(tracks: [
            Track(id: "processable", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "recovery hold should stop full-library writes")
            return
        }
        #expect(message == "Previous run needs recovery before writes continue.")
        #expect(await recorder.recordedCallCount() == 0)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("empty full library processing scope skips mutation metadata preparation")
    func emptyFullLibraryProcessingScopeSkipsMutationMetadataPreparation() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { _, _ in [] },
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false

        viewModel.start(tracks: [
            Track(id: "filtered", name: "Orion", artist: "Metallica", album: "Master of Puppets"),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        #expect(await recorder.recordedCallCount() == 0)
        #expect(await recorder.preparedTrackIDs.isEmpty)
    }
}

private enum MutationPreparationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "metadata preparation failed"
    }
}
