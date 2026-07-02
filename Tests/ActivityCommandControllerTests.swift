import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityCommandController")
@MainActor
struct ActivityCommandControllerTests {
    @Test("review changes command returns navigation result")
    func reviewChangesCommandReturnsNavigationResult() async {
        let harness = Harness(projection: makeReviewProjection(revision: ProjectionRevision(2)))
        let controller = harness.makeController()

        let result = await controller.handle(.reviewChanges())

        #expect(result.status == .navigated)
        #expect(result.message == "Opening review.")
        #expect(result.navigationTarget == .fixPlan(id: "current"))
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(3))
        #expect(harness.syncCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("review changes command rejects stale empty plan")
    func reviewChangesCommandRejectsStaleEmptyPlan() async {
        let harness = Harness(currentRevision: ProjectionRevision(2))
        let controller = harness.makeController()

        let result = await controller.handle(.reviewChanges())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Review plan is no longer available.")
        #expect(result.navigationTarget == nil)
        #expect(result.refreshedActivityProjection?.revision == ProjectionRevision(3))
        #expect(harness.syncCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("run manually command runs sync")
    func runManuallyCommandRunsSync() async {
        let harness = Harness(currentRevision: ProjectionRevision(2))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected.")
        #expect(harness.syncCallCount == 1)
        #expect(harness.reloadCallCount == 1)
        #expect(harness.refreshCallCount == 3)
    }

    @Test("already running sync returns already covered")
    func alreadyRunningSyncReturnsAlreadyCovered() async {
        let harness = Harness(isSynchronizing: true)
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .alreadyCovered)
        #expect(result.message == "A library sync is already running.")
        #expect(harness.syncCallCount == 0)
        #expect(harness.refreshCallCount == 0)
    }

    @Test("unavailable sync service returns temporary unavailable")
    func unavailableSyncServiceReturnsTemporaryUnavailable() async {
        let harness = Harness(isSyncAvailable: false)
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .temporaryUnavailable)
        #expect(result.issue?.id == "library-sync-unavailable")
        #expect(result.issue?.category == .temporaryUnavailable)
        #expect(harness.syncCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("run manually rejects stale disabled command")
    func runManuallyRejectsStaleDisabledCommand() async {
        let harness = Harness(projection: makeRunManuallyProjection(
            revision: ProjectionRevision(2),
            isEnabled: false
        ))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .rejectedStale)
        #expect(result.message == "Manual sync is no longer available.")
        #expect(harness.syncCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("run manually rechecks active sync after stale guard refresh")
    func runManuallyRechecksActiveSyncAfterStaleGuardRefresh() async {
        let harness = Harness(marksSynchronizingOnFirstRefresh: true)
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .alreadyCovered)
        #expect(result.message == "A library sync is already running.")
        #expect(harness.syncCallCount == 0)
        #expect(harness.reloadCallCount == 0)
        #expect(harness.refreshCallCount == 1)
    }

    @Test("no delta sync returns no op")
    func noDeltaSyncReturnsNoOp() async {
        let harness = Harness(syncResult: SyncResult())
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .noOp)
        #expect(result.message == "No library changes detected.")
        #expect(harness.syncCallCount == 1)
        #expect(harness.reloadCallCount == 1)
        #expect(harness.lastSyncResult?.hasChanges == false)
        #expect(harness.syncErrorMessage == nil)
        #expect(harness.isSynchronizing == false)
    }

    @Test("changed sync returns accepted with all delta arrays counted")
    func changedSyncReturnsAcceptedWithAllDeltaArraysCounted() async {
        let harness = Harness(
            syncResult: SyncResult(
                newTracks: [track(id: "NEW")],
                modifiedTracks: [track(id: "MODIFIED")],
                identityChangedTracks: [track(id: "IDENTITY")],
                refreshedTracks: [track(id: "REFRESHED")],
                removedTrackIDs: ["REMOVED"]
            )
        )
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .accepted)
        #expect(result.message == "Library delta detected · analyzing 5 changes.")
        #expect(harness.lastSyncResult?.hasChanges == true)
        #expect(harness.syncErrorMessage == nil)
        #expect(harness.isSynchronizing == false)
    }

    @Test("sync error returns requires attention")
    func syncErrorReturnsRequiresAttention() async {
        let harness = Harness(syncError: TestError(message: "Music.app is unavailable"))
        let controller = harness.makeController()

        let result = await controller.handle(.runManually())

        #expect(result.status == .requiresAttention)
        #expect(result.issue?.id == "library-sync-failed")
        #expect(result.issue?.summary == "Library sync failed")
        #expect(harness.lastSyncResult == nil)
        #expect(harness.syncErrorMessage == "Music.app is unavailable")
        #expect(harness.isSynchronizing == false)
    }

    private func track(id: String) -> Core.Track {
        Core.Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
    }

    private func makeReviewProjection(revision: ProjectionRevision) -> ActivityProjection {
        ActivityProjection(
            revision: revision,
            title: "Fix plan ready",
            subtitle: "2 candidate fixes",
            syncStatusText: "Synced just now",
            currentStage: .diff,
            processingMode: .preview,
            automationState: .manualScanOnly,
            deltaCount: 2,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: ActivityCommandDescriptor(
                id: "review-changes",
                title: "Review changes",
                style: .primary,
                isEnabled: true,
                commandKind: .reviewChanges
            ),
            secondaryCommand: nil,
            stageDescriptors: [],
            recentActivity: [],
            summaryCards: [],
            operationalIssues: []
        )
    }
}

private func makeRunManuallyProjection(
    revision: ProjectionRevision,
    isEnabled: Bool
) -> ActivityProjection {
    ActivityProjection(
        revision: revision,
        title: "Library ready",
        subtitle: "Library ready",
        syncStatusText: "Synced just now",
        currentStage: .detect,
        processingMode: .preview,
        automationState: .manualScanOnly,
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
            isEnabled: isEnabled,
            commandKind: .runManually
        ),
        stageDescriptors: [],
        recentActivity: [],
        summaryCards: [],
        operationalIssues: []
    )
}

@MainActor
private final class Harness {
    var isSynchronizing: Bool
    var isSyncAvailable: Bool
    var lastSyncResult: SyncResult?
    var syncErrorMessage: String?
    var syncCallCount = 0
    var reloadCallCount = 0
    var refreshCallCount = 0

    private var projection: ActivityProjection
    private let syncResult: SyncResult
    private let syncError: Error?
    private let marksSynchronizingOnFirstRefresh: Bool

    init(
        currentRevision: ProjectionRevision = ProjectionRevision(1),
        projection: ActivityProjection? = nil,
        isSynchronizing: Bool = false,
        isSyncAvailable: Bool = true,
        syncResult: SyncResult = SyncResult(),
        syncError: Error? = nil,
        marksSynchronizingOnFirstRefresh: Bool = false
    ) {
        self.projection = projection ?? makeRunManuallyProjection(revision: currentRevision, isEnabled: true)
        self.isSynchronizing = isSynchronizing
        self.isSyncAvailable = isSyncAvailable
        self.syncResult = syncResult
        self.syncError = syncError
        self.marksSynchronizingOnFirstRefresh = marksSynchronizingOnFirstRefresh
    }

    func makeController() -> ActivityCommandController {
        ActivityCommandController(
            currentProjection: { self.projection },
            isSynchronizingLibrary: { self.isSynchronizing },
            isLibrarySyncAvailable: { self.isSyncAvailable },
            setSynchronizingLibrary: { self.isSynchronizing = $0 },
            setLastSyncResult: { self.lastSyncResult = $0 },
            setSyncErrorMessage: { self.syncErrorMessage = $0 },
            synchronizeLibraryNow: {
                self.syncCallCount += 1
                if let syncError = self.syncError {
                    throw syncError
                }
                return self.syncResult
            },
            reloadLibrary: { forceRefresh in
                if forceRefresh {
                    self.reloadCallCount += 1
                }
            },
            refreshActivityProjection: {
                self.refreshCallCount += 1
                if self.marksSynchronizingOnFirstRefresh, self.refreshCallCount == 1 {
                    self.isSynchronizing = true
                }
                self.projection = self.projection.withRevision(self.projection.revision.advanced())
                return self.projection
            }
        )
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
