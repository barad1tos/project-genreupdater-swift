import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow release-year restore")
@MainActor
struct YearRestoreTests {
    @Test("Release-year restore marks tied consensus tracks as skipped")
    func releaseYearRestoreMarksTiedConsensusTracksAsSkipped() async {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "tie-1997",
                name: "First Tie",
                artist: "The Cure",
                album: "Wish",
                year: 2025,
                releaseYear: 1997
            ),
            Track(
                id: "tie-2001",
                name: "Second Tie",
                artist: "The Cure",
                album: "Wish",
                year: 2025,
                releaseYear: 2001
            ),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "tied release-year restore should complete without writes")
            return
        }
        #expect(viewModel.result?.entries.isEmpty == true)
        #expect(viewModel.result?.noOpEntries.isEmpty == true)
        #expect(viewModel.failedCount == 0)
        #expect(viewModel.trackStatuses["tie-1997"] == .skipped)
        #expect(viewModel.trackStatuses["tie-2001"] == .skipped)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("Release-year restore empty scope skips mutation metadata preparation")
    func releaseYearRestoreEmptyScopeSkipsMutationMetadataPreparation() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "already-restored",
                name: "Plainsong",
                artist: "The Cure",
                album: "Disintegration",
                year: 1989,
                releaseYear: 1989
            ),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        #expect(await recorder.recordedCallCount() == 0)
        #expect(await recorder.preparedTrackIDs.isEmpty)
        guard case .done = viewModel.phase else {
            #expect(Bool(false), "empty release-year restore should complete")
            return
        }
    }

    @Test("Release-year restore stops when recovery hold is active")
    func releaseYearRestoreStopsWhenRecoveryHoldIsActive() async {
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            ensureRecoveryHold: { true },
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "restore-target",
                name: "Plainsong",
                artist: "The Cure",
                album: "Disintegration",
                year: 2025,
                releaseYear: 1989
            ),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "recovery hold should stop release-year restore writes")
            return
        }
        #expect(message == "Previous run needs recovery before writes continue.")
        #expect(await recorder.recordedCallCount() == 0)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("Release-year restore ignores reentry while recovery check is pending")
    func releaseYearRestoreIgnoresReentryWhileRecoveryCheckIsPending() async {
        let recoveryHold = MutationPreparationHold()
        let recorder = MutationPreparationRecorder()
        let fixture = makeWorkflowFixture(
            ensureRecoveryHold: {
                await recoveryHold.hold()
                return false
            },
            prepareMutationMetadata: { tracks in
                await recorder.record(tracks)
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5
        let tracks = [
            Track(
                id: "restore-target",
                name: "Plainsong",
                artist: "The Cure",
                album: "Disintegration",
                year: 2025,
                releaseYear: 1989
            ),
        ]

        viewModel.start(tracks: tracks)
        await recoveryHold.waitUntilStarted()
        viewModel.start(tracks: tracks)
        await recoveryHold.release()
        await viewModel.processingTask?.value
        await Task.yield()

        #expect(await recorder.recordedCallCount() == 1)
    }

    @Test("Release-year restore cancellation during preparation returns to configuration")
    func releaseYearRestoreCancellationDuringPreparationReturnsToConfiguration() async {
        let hold = MutationPreparationHold()
        let fixture = makeWorkflowFixture(
            prepareMutationMetadata: { _ in
                await hold.hold()
                try Task.checkCancellation()
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "restore-target",
                name: "Plainsong",
                artist: "The Cure",
                album: "Disintegration",
                year: 2025,
                releaseYear: 1989
            ),
        ])
        await hold.waitUntilStarted()
        let processingTask = viewModel.processingTask

        viewModel.cancel()
        await hold.release()
        await processingTask?.value
        await Task.yield()

        guard case .configure = viewModel.phase else {
            #expect(Bool(false), "cancelled release-year preparation should return to configuration")
            return
        }
        #expect(viewModel.progress == nil)
        #expect(viewModel.result == nil)
    }

    @Test("Release-year restore completed run cancel preserves terminal phase")
    func releaseYearRestoreCompletedRunCancelPreservesTerminalPhase() async {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "already-restored",
                name: "Plainsong",
                artist: "The Cure",
                album: "Disintegration",
                year: 1989,
                releaseYear: 1989
            ),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "restore should complete before stale cancel")
            return
        }

        viewModel.cancel()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "stale cancel should not reset a terminal restore phase")
            return
        }
    }
}
