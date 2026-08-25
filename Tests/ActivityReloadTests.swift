import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Activity reload coordination")
@MainActor
struct ActivityReloadTests {
    @Test("queued reload waits for queued manual terminal")
    func waitsForQueuedTerminal() {
        let activeRunID = RunID()
        let activeTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            runID: activeRunID,
            trigger: .backgroundSync
        )

        let afterActive = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: activeTerminal)

        #expect(afterActive.next == .waitingForQueued)
        #expect(!afterActive.shouldReload)

        let queuedTerminal = ActivityFixtures.lifecycle(phase: .finished(
            .completedNoOp(SyncResult()),
            finishedAt: ActivityFixtures.finishDate
        ))
        let afterQueued = advanceQueuedReload(afterActive.next, lifecycle: queuedTerminal)

        #expect(afterQueued.next == nil)
        #expect(afterQueued.shouldReload)
    }

    @Test("queued reload clears after replacement terminal")
    func clearsAfterReplacement() {
        let activeRunID = RunID()
        let activeTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            runID: activeRunID,
            trigger: .backgroundSync
        )
        let afterActive = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: activeTerminal)

        let previewTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            trigger: .manualCheck,
            intent: .previewFixes
        )
        let afterPreview = advanceQueuedReload(afterActive.next, lifecycle: previewTerminal)

        #expect(afterPreview.next == nil)
        #expect(afterPreview.shouldReload)

        let directManualTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate)
        )
        let afterDirectManual = advanceQueuedReload(afterPreview.next, lifecycle: directManualTerminal)

        #expect(afterDirectManual.next == nil)
        #expect(!afterDirectManual.shouldReload)
    }

    @Test("queued reload tolerates missed active terminal")
    func missedActiveQueues() {
        let activeRunID = RunID()
        let queuedTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            trigger: .manualCheck
        )

        let afterQueued = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: queuedTerminal)

        #expect(afterQueued.next == nil)
        #expect(afterQueued.shouldReload)
    }

    @Test("queued reload clears replacement after missed active terminal")
    func missedActiveClears() {
        let activeRunID = RunID()
        let previewTerminal = ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            trigger: .manualCheck,
            intent: .previewFixes
        )

        let afterPreview = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: previewTerminal)

        #expect(afterPreview.next == nil)
        #expect(afterPreview.shouldReload)
    }

    @Test("queued reload remains pending through recovery suspension")
    func recoveryPreservesReload() {
        let activeRunID = RunID()
        let recoverable = ActivityFixtures.lifecycle(
            phase: .suspended(.recoverable),
            runID: activeRunID,
            trigger: .backgroundSync
        )

        let advance = advanceQueuedReload(.waitingForActive(activeRunID), lifecycle: recoverable)

        #expect(advance.next == .waitingForActive(activeRunID))
        #expect(!advance.shouldReload)
    }

    // D4: the graph-level wrapper — write-back, reload firing, and the
    // active-lifecycle guard — pinned beyond the pure truth table.
    @Test("a terminal boundary consumes the queue and reloads")
    func terminalReloadsLibrary() async throws {
        let dependencies = try makeDependencies()
        installMenuMirror(on: dependencies)
        dependencies.queuedManualReload = .waitingForQueued

        await dependencies.advanceQueuedReloadForBoundary(ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate)
        ))

        #expect(dependencies.queuedManualReload == nil)
        #expect(dependencies.libraryTracks.map(\.id) == ["menu-live"])
    }

    @Test("a matching terminal advances to waiting-for-queued without reloading")
    func matchingTerminalWaits() async throws {
        let dependencies = try makeDependencies()
        installMenuMirror(on: dependencies)
        let activeRunID = RunID()
        dependencies.queuedManualReload = .waitingForActive(activeRunID)

        await dependencies.advanceQueuedReloadForBoundary(ActivityFixtures.lifecycle(
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: ActivityFixtures.finishDate),
            runID: activeRunID
        ))

        #expect(dependencies.queuedManualReload == .waitingForQueued)
        #expect(dependencies.libraryTracks.isEmpty)
    }

    @Test("an active boundary leaves the queue and library untouched")
    func activeBoundaryKeepsQueue() async throws {
        let dependencies = try makeDependencies()
        installMenuMirror(on: dependencies)
        dependencies.queuedManualReload = .waitingForQueued

        await dependencies.advanceQueuedReloadForBoundary(ActivityFixtures.lifecycle(
            phase: .active(.writing)
        ))

        #expect(dependencies.queuedManualReload == .waitingForQueued)
        #expect(dependencies.libraryTracks.isEmpty)
    }

    // D4: the menu's ActivityCommands write the REAL coordination state —
    // the no-op policy is closed; menus behave like the activity surface.
    @Test("the menu queue closure writes the shared reload machine")
    func menuQueueWritesState() throws {
        let dependencies = try makeDependencies()
        let commands = dependencies.makeMenuActivityCommands()
        let runID = RunID()

        commands.queueManualReload(runID)

        #expect(dependencies.queuedManualReload == .waitingForActive(runID))
    }

    @Test("the menu reload closure loads the library headlessly")
    func menuReloadsLibrary() async throws {
        let dependencies = try makeDependencies()
        installMenuMirror(on: dependencies)
        let commands = dependencies.makeMenuActivityCommands()

        await commands.reloadLibrary(true)

        #expect(dependencies.libraryTracks.map(\.id) == ["menu-live"])
    }

    private func makeDependencies() throws -> AppDependencies {
        try makeFixture(testArtists: []).dependencies
    }

    private func installMenuMirror(on dependencies: AppDependencies) {
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [
                Core.Track(id: "menu-live", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
            ]),
            runRecordStore: RunRecordStoreStub()
        )
    }
}
